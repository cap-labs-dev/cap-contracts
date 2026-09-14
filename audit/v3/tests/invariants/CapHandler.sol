// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";

/// @dev The ERC-7540 + PremiumVesting surface shared by Stablecoin, Tranche and Underwriter, so
/// the handler and the invariants can treat all six vaults uniformly.
interface IVaultLike {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function redemptionQueue() external view returns (uint256);
    function unlockedSupply() external view returns (uint256);
    function instantUnlockedSupply() external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function maxInstantRedeem(address) external view returns (uint256);
    function controllerOf(uint256) external view returns (address);
    function claimableRedeemRequest(uint256, address) external view returns (uint256);
    function pendingRedeemRequest(uint256, address) external view returns (uint256);
    function stakedSupply() external view returns (uint256);
    function optedIn(address) external view returns (bool);
    function claimable(address) external view returns (uint256);
    function remaining() external view returns (uint256);
    function vested() external view returns (uint256);
}

interface ICapWorld {
    function stable() external view returns (Stablecoin);
    function underlying() external view returns (MockERC20);
    function warpBy(uint256) external;
    function setCollateralPrice(uint256) external;
    // stablecoin
    function depositStable(address, uint256) external returns (uint256);
    function instantRedeemStable(address, uint256) external;
    function requestRedeemStable(address, uint256) external returns (uint256);
    function claimStable(address, uint256, uint256) external;
    function claimStableFifo(address, uint256) external;
    function transferStableRequest(address, uint256, address) external;
    function coverBadDebt(uint256) external returns (uint256);
    // any ERC-7540 vault (tranche / underwriter)
    function fundTrancheFor(address, address, uint256) external;
    function fundUnderwriterFor(address, uint256) external;
    function instantRedeemVault(address, address, uint256) external;
    function requestRedeemVault(address, address, uint256) external returns (uint256);
    function claimVault(address, address, uint256, uint256) external;
    function claimVaultFifo(address, address, uint256) external;
    function claimPremium(address, address) external;
    // underwriter (curator / allocator / keeper = the test contract)
    function uwAllocate(address, uint256) external;
    function uwDeallocate(address, uint256) external returns (uint256);
    function uwDeallocateAsync(address, uint256) external returns (uint256);
    function uwFinalize(address, uint256, uint256) external;
    function uwReport(address) external;
    // floating market
    function borrowFloating(uint256) external returns (uint256);
    function repayFloating(uint256) external;
    function liquidateFloating(uint256) external;
    function writeOffFloating() external;
    // fixed market
    function borrowFixed(uint256, uint256) external returns (uint256);
    function repayFixed(uint256, uint256) external;
    function extendAdminFixed(uint256) external;
    function liquidateFixed(uint256, uint256) external;
    function writeOffFixed(uint256) external;
    // risk parameters
    function setLt(address, uint256) external;
    function setLiquidationBonus(uint256) external;
}

/// @title CapHandler (round 3, HEAD a843c1d, 6-decimal underlying)
/// @notice Stateful handler driving every user-facing and privileged entry point of a full Cap
/// deployment. Every world call is wrapped in try/catch and preconditioned, so the campaign runs
/// under `fail_on_revert = true`; expected reverts are counted in `ghost_reverts`.
contract CapHandler {
    ICapWorld internal immutable D;

    address[] public depositors; // stablecoin depositors
    address[] public underwriters; // tranche + underwriter-vault depositors
    address public liquidator;
    address public guardian; // = the test contract (holds GUARDIAN/GOVERNOR/KEEPER/curator/allocator)

    FloatingMarket public floating;
    FixedMarket public fixedM;
    Tranche public senior;
    Tranche public junior;
    Tranche public fSenior;
    Tranche public fJunior;
    Underwriter public uw;

    // ───── ghosts ─────
    uint256 public ghost_badDebtRecognized;
    uint256 public ghost_badDebtCovered;
    uint256 public ghost_badDebtRetiredOnRedeem;
    uint256 public ghost_lastSeniorPrice;
    uint256 public ghost_lastJuniorPrice;
    bool public ghost_priceDropWithoutSlash;
    uint256 public ghost_slashCount;
    uint256 public ghost_roundTripExcess; // underlying paid out above deposit on an immediate round trip
    uint256 public ghost_reverts; // expected reverts swallowed by try/catch
    mapping(bytes4 => uint256) public ghost_revertsBySelector;
    uint256 public ghost_floatDebtOverCredit; // times floating.totalDebt() read above creditBackedSupply
    uint256 public ghost_ltSets;
    /// share-moving tranche actions since deploy: each may gift <= 1 wei to remaining holders by
    /// flooring on the mover's side, which is the documented tolerance on I37 (WS-C, C7)
    uint256 public ghost_shareOps;
    uint256 public ghost_bonusSets;
    uint256 public calls;

    /// @dev Highest request id issued on each vault. Ids are sequential from 1, so this is also
    /// the number of requests ever made there (by anyone, since every requester goes through here).
    mapping(address => uint256) public requestCount;
    uint256[] public stableRequestIds;
    mapping(uint256 => address) public stableRequestController;

    struct UwRequest {
        address tranche;
        uint256 id;
    }

    UwRequest[] public uwRequests;
    uint256[] public fixedLoans;

    constructor(
        ICapWorld d,
        address[] memory deps,
        address[] memory uws,
        address liq,
        FloatingMarket fl,
        FixedMarket fx,
        Tranche[4] memory tr,
        Underwriter u
    ) {
        D = d;
        depositors = deps;
        underwriters = uws;
        liquidator = liq;
        guardian = address(d);
        floating = fl;
        fixedM = fx;
        senior = tr[0];
        junior = tr[1];
        fSenior = tr[2];
        fJunior = tr[3];
        uw = u;
        ghost_lastSeniorPrice = _price(senior);
        ghost_lastJuniorPrice = _price(junior);
    }

    // ───── helpers ─────
    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    /// @dev previewRedeem now reverts (PreviewNotSupported); share price is read off convertToAssets
    function _price(Tranche t) internal view returns (uint256) {
        return t.totalSupply() == 0 ? 1e18 : t.convertToAssets(1e18);
    }

    function _snapPrices() internal {
        ghost_lastSeniorPrice = _price(senior);
        ghost_lastJuniorPrice = _price(junior);
    }

    function _checkPriceMonotone(bool slashHappened) internal {
        uint256 s = _price(senior);
        uint256 j = _price(junior);
        if (!slashHappened) {
            // allow 1 wei of rounding movement
            if (s + 1 < ghost_lastSeniorPrice || j + 1 < ghost_lastJuniorPrice) ghost_priceDropWithoutSlash = true;
        }
        ghost_lastSeniorPrice = s;
        ghost_lastJuniorPrice = j;
    }

    function _revert(bytes memory err) internal {
        ghost_reverts++;
        bytes4 sel;
        if (err.length >= 4) {
            assembly {
                sel := mload(add(err, 0x20))
            }
        }
        ghost_revertsBySelector[sel]++;
    }

    function _badDebtDelta(uint256 before) internal {
        uint256 bd2 = D.stable().badDebt();
        if (before > bd2) ghost_badDebtRetiredOnRedeem += before - bd2;
    }

    modifier count() {
        calls++;
        _;
    }

    // ───── time & price ─────
    function warp(uint256 dt) external count {
        dt = _bound(dt, 1, 30 days);
        D.warpBy(dt);
        _checkPriceMonotone(false);
    }

    function movePrice(uint256 bps) external count {
        // collateral price between 0.5 and 1.5 of par, posted through the mock Chainlink feed
        bps = _bound(bps, 5000, 15000);
        D.setCollateralPrice(1e18 * bps / 10000);
        _checkPriceMonotone(false);
    }

    // ───── stablecoin depositors (amounts in 6-dec underlying base units) ─────
    function stableDeposit(uint256 who, uint256 amount) external count {
        address a = depositors[who % depositors.length];
        amount = _bound(amount, 1e6, 1_000_000e6);
        try D.depositStable(a, amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function stableRedeemInstant(uint256 who, uint256 shares) external count {
        address a = depositors[who % depositors.length];
        uint256 max = D.stable().maxInstantRedeem(a);
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        uint256 bd = D.stable().badDebt();
        try D.instantRedeemStable(a, shares) {
            _badDebtDelta(bd);
        }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    /// @dev deposit then immediately redeem the same shares; must never pay out more than put in
    function stableRoundTrip(uint256 who, uint256 amount) external count {
        address a = depositors[who % depositors.length];
        amount = _bound(amount, 1e6, 100_000e6);
        uint256 shares;
        try D.depositStable(a, amount) returns (uint256 s) {
            shares = s;
        } catch (bytes memory e) {
            _revert(e);
            return;
        }
        uint256 before = D.underlying().balanceOf(a); // after the mint+deposit: net of this call so far
        uint256 max = D.stable().maxInstantRedeem(a);
        if (max < shares) return; // cannot round-trip; leave the deposit
        uint256 bd = D.stable().badDebt();
        try D.instantRedeemStable(a, shares) {
            _badDebtDelta(bd);
        } catch (bytes memory e) {
            _revert(e);
            return;
        }
        uint256 after_ = D.underlying().balanceOf(a);
        if (after_ > before + amount) ghost_roundTripExcess += after_ - before - amount;
    }

    function stableRequestRedeem(uint256 who, uint256 shares) external count {
        address a = depositors[who % depositors.length];
        uint256 bal = D.stable().balanceOf(a);
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        try D.requestRedeemStable(a, shares) returns (uint256 id) {
            stableRequestIds.push(id);
            stableRequestController[id] = a;
            requestCount[address(D.stable())] = id;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    /// @dev 4-arg claim of one request
    function stableClaim(uint256 idx, uint256 shares) external count {
        if (stableRequestIds.length == 0) return;
        uint256 id = stableRequestIds[idx % stableRequestIds.length];
        address a = stableRequestController[id];
        uint256 max = D.stable().claimableRedeemRequest(id, a);
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        uint256 bd = D.stable().badDebt();
        try D.claimStable(a, id, shares) {
            _badDebtDelta(bd);
        }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    /// @dev 3-arg FIFO claim across the controller's requests
    function stableClaimFifo(uint256 who, uint256 shares) external count {
        address a = depositors[who % depositors.length];
        uint256 max = D.stable().maxRedeem(a);
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        uint256 bd = D.stable().badDebt();
        try D.claimStableFifo(a, shares) {
            _badDebtDelta(bd);
        }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    function stableTransferRequest(uint256 idx, uint256 toWho) external count {
        if (stableRequestIds.length == 0) return;
        uint256 id = stableRequestIds[idx % stableRequestIds.length];
        address from = D.stable().controllerOf(id);
        if (from == address(0)) return; // fully settled
        address to = depositors[toWho % depositors.length];
        try D.transferStableRequest(from, id, to) {
            stableRequestController[id] = to;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function coverBadDebt(uint256 amount) external count {
        uint256 bd = D.stable().badDebt();
        if (bd == 0) return;
        amount = _bound(amount, 1, bd);
        try D.coverBadDebt(amount) returns (uint256 covered) {
            ghost_badDebtCovered += covered;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── tranche / underwriter depositors (collateral, 18 dec) ─────
    function trancheDeposit(uint256 who, uint256 which, uint256 amount) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        Tranche t = _pick(which);
        if (t.killed()) return;
        amount = _bound(amount, 2e3, 500e18);
        try D.fundTrancheFor(address(t), a, amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function uwDeposit(uint256 who, uint256 amount) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        amount = _bound(amount, 2e3, 500e18);
        try D.fundUnderwriterFor(a, amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function vaultRedeemInstant(uint256 who, uint256 which, uint256 shares) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        IVaultLike v = _pickVault(which);
        uint256 max;
        try v.maxInstantRedeem(a) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        try D.instantRedeemVault(address(v), a, shares) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function vaultRequestRedeem(uint256 who, uint256 which, uint256 shares) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        IVaultLike v = _pickVault(which);
        uint256 bal = v.balanceOf(a);
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        try D.requestRedeemVault(address(v), a, shares) returns (uint256 id) {
            requestCount[address(v)] = id;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function vaultClaim(uint256 who, uint256 which, uint256 id, uint256 shares) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        IVaultLike v = _pickVault(which);
        uint256 n = requestCount[address(v)];
        if (n == 0) return;
        id = 1 + (id % n);
        uint256 max;
        try v.claimableRedeemRequest(id, a) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        try D.claimVault(address(v), a, id, shares) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function vaultClaimFifo(uint256 who, uint256 which, uint256 shares) external count {
        ghost_shareOps++;
        address a = underwriters[who % underwriters.length];
        IVaultLike v = _pickVault(which);
        uint256 max;
        try v.maxRedeem(a) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        try D.claimVaultFifo(address(v), a, shares) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function vaultClaimPremium(uint256 who, uint256 which) external count {
        address a = underwriters[who % underwriters.length];
        try D.claimPremium(address(_pickVault(which)), a) { }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── underwriter curator / allocator / keeper ─────
    function uwAllocate(uint256 which, uint256 amount) external count {
        ghost_shareOps++;
        Tranche t = _pick(which);
        if (t.killed()) return;
        uint256 idle = uw.unlockedSupply(); // quote of the idle vault balance, in shares == assets at par
        if (idle == 0) return;
        amount = _bound(amount, 1, idle);
        try D.uwAllocate(address(t), amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function uwDeallocate(uint256 which, uint256 shares) external count {
        ghost_shareOps++;
        Tranche t = _pick(which);
        uint256 bal = t.balanceOf(address(uw));
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        try D.uwDeallocate(address(t), shares) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function uwDeallocateAsync(uint256 which, uint256 shares) external count {
        ghost_shareOps++;
        Tranche t = _pick(which);
        uint256 bal = t.balanceOf(address(uw));
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        try D.uwDeallocateAsync(address(t), shares) returns (uint256 id) {
            uwRequests.push(UwRequest(address(t), id));
            requestCount[address(t)] = id;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function uwFinalize(uint256 idx, uint256 shares) external count {
        ghost_shareOps++;
        if (uwRequests.length == 0) return;
        UwRequest memory r = uwRequests[idx % uwRequests.length];
        uint256 recorded = uw.queuedRequest(r.tranche, r.id);
        if (recorded == 0) return;
        uint256 claimable = Tranche(r.tranche).claimableRedeemRequest(r.id, address(uw));
        if (claimable == 0) return;
        shares = _bound(shares, 1, claimable < recorded ? claimable : recorded);
        try D.uwFinalize(r.tranche, r.id, shares) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function uwReport(uint256 which) external count {
        try D.uwReport(address(_pick(which))) { }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── floating market ─────
    function floatBorrow(uint256 amount) external count {
        uint256 credit = floating.availableCredit();
        if (credit == 0) return;
        amount = _bound(amount, 1, credit);
        try D.borrowFloating(amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
        _checkPriceMonotone(false);
    }

    function floatRepay(uint256 amount) external count {
        floating.chargePremium();
        uint256 debt = floating.totalDebt();
        // round-2 A-1 guard: if the floating reading ever sits above creditBackedSupply, a full
        // repay underflows burnCreditBacked. I30 asserts this cannot happen; the guard only keeps
        // the campaign alive and records how often it was needed.
        uint256 credit = D.stable().creditBackedSupply();
        if (debt > credit) {
            ghost_floatDebtOverCredit++;
            if (credit < 2) return;
            debt = credit - 1;
        }
        uint256 minUnit = floating.index() / 1e27 + 1; // below one scaled unit repay reverts by design
        if (debt < minUnit) return;
        amount = _bound(amount, minUnit, debt);
        try D.repayFloating(amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    function floatCharge() external count {
        floating.chargePremium();
        _checkPriceMonotone(false);
    }

    function floatLiquidate(uint256 amount) external count {
        ghost_shareOps++;
        if (floating.healthiness() >= 1e27) return;
        uint256 max = floating.maxLiquidatable();
        uint256 minUnit = floating.index() / 1e27 + 1;
        if (max < minUnit) return;
        amount = _bound(amount, minUnit, max);
        _snapPrices();
        try D.liquidateFloating(amount) {
            ghost_slashCount++;
            _checkPriceMonotone(true);
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function floatWriteOff() external count {
        floating.chargePremium();
        if (floating.unrecoverableDebt() < floating.index() / 1e27 + 1) return; // sub-unit write-off reverts by design
        uint256 bd = D.stable().badDebt();
        try D.writeOffFloating() {
            ghost_badDebtRecognized += D.stable().badDebt() - bd;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── fixed market ─────
    function fixedBorrow(uint256 amount, uint256 term) external count {
        term = _bound(term, fixedM.minimumTermLimit(), fixedM.maximumTermLimit());
        uint256 credit = fixedM.availableCredit(term);
        if (credit == 0) return;
        amount = _bound(amount, 1, credit);
        try D.borrowFixed(amount, term) returns (uint256 id) {
            fixedLoans.push(id);
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function fixedRepay(uint256 idx, uint256 amount) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        uint256 debt = fixedM.debt(id);
        if (debt == 0) return;
        amount = _bound(amount, 1, debt);
        try D.repayFixed(id, amount) { }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    function fixedExtendAdmin(uint256 idx) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        if (fixedM.debt(id) == 0) return;
        if (block.timestamp < fixedM.expiry(id) + fixedM.grace()) return;
        try D.extendAdminFixed(id) { }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    function fixedLiquidate(uint256 idx, uint256 amount) external count {
        ghost_shareOps++;
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        uint256 debt = fixedM.debt(id);
        if (debt == 0) return;
        if (fixedM.healthiness() >= 1e27) return;
        uint256 max = fixedM.maxLiquidatable();
        if (max == 0) return;
        amount = _bound(amount, 1, max < debt ? max : debt);
        _snapPrices();
        try D.liquidateFixed(id, amount) {
            ghost_slashCount++;
            _checkPriceMonotone(true);
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    function fixedWriteOff(uint256 idx) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        if (fixedM.debt(id) == 0 || fixedM.unrecoverableDebt() == 0) return;
        uint256 bd = D.stable().badDebt();
        try D.writeOffFixed(id) {
            ghost_badDebtRecognized += D.stable().badDebt() - bd;
        } catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── risk parameters (I38 exploration) ─────
    /// @dev GUARDIAN. Permitted range on the market is (buffer, 1e27].
    function setLt(uint256 which, uint256 lt) external count {
        address m = which % 2 == 0 ? address(floating) : address(fixedM);
        uint256 buf = FloatingMarket(m).buffer();
        // a quarter of the draws sit in the top 10% of the band so the fuzzer actually visits the
        // edge; the rest span the whole permitted range
        lt = lt % 4 == 0 ? _bound(lt >> 2, 0.9e27, 1e27) : _bound(lt, buf + 1, 1e27);
        try D.setLt(m, lt) {
            ghost_ltSets++;
        }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    /// @dev GOVERNOR. Permitted range on the IRM is [0, 0.1e27].
    function setLiquidationBonus(uint256 bonus) external count {
        bonus = bonus % 4 == 0 ? _bound(bonus >> 2, 0.05e27, 0.1e27) : _bound(bonus, 0, 0.1e27);
        try D.setLiquidationBonus(bonus) {
            ghost_bonusSets++;
        }
            catch (bytes memory e) {
            _revert(e);
        }
    }

    // ───── selection & views ─────
    function _pick(uint256 which) internal view returns (Tranche) {
        which %= 4;
        if (which == 0) return senior;
        if (which == 1) return junior;
        if (which == 2) return fSenior;
        return fJunior;
    }

    function _pickVault(uint256 which) internal view returns (IVaultLike) {
        which %= 5;
        if (which == 4) return IVaultLike(address(uw));
        return IVaultLike(address(_pick(which)));
    }

    function stableRequestCount() external view returns (uint256) {
        return stableRequestIds.length;
    }

    function uwRequestCount() external view returns (uint256) {
        return uwRequests.length;
    }

    function fixedLoanCount() external view returns (uint256) {
        return fixedLoans.length;
    }
}
