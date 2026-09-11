// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../contracts/cap/market/FloatingMarket.sol";
import { MockERC20 } from "../../../test/shared/mocks/MockERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";

interface ICapWorld {
    function stable() external view returns (Stablecoin);
    function underlying() external view returns (MockERC20);
    function warpBy(uint256) external;
    function setCollateralPrice(uint256) external;
    function depositStable(address, uint256) external returns (uint256);
    function redeemStable(address, uint256) external;
    function requestRedeemStable(address, uint256) external returns (uint256);
    function claimStable(address, uint256, uint256) external;
    function coverBadDebt(uint256) external returns (uint256);
    function fundTrancheFor(address, address, uint256) external;
    function redeemTranche(address, address, uint256) external;
    function requestRedeemTranche(address, address, uint256) external;
    function trancheRequestCount(address) external view returns (uint256);
    function claimTranche(address, address, uint256, uint256) external;
    function claimPremium(address, address) external;
    function borrowFloating(uint256) external;
    function repayFloating(uint256) external;
    function liquidateFloating(uint256) external;
    function writeOffFloating() external;
    function borrowFixed(uint256, uint256) external returns (uint256);
    function repayFixed(uint256, uint256) external;
    function extendAdminFixed(uint256) external;
    function liquidateFixed(uint256, uint256) external;
    function writeOffFixed(uint256) external;
}

/// @title CapHandler
/// @notice Stateful handler driving every user-facing and privileged entry point of a full Cap
/// deployment with bounded, non-reverting calls, plus ghost variables the invariants read.
contract CapHandler {
    ICapWorld internal immutable D;

    address[] public depositors; // stablecoin depositors
    address[] public underwriters; // tranche depositors
    address public liquidator;
    address public guardian; // = deployer (holds GUARDIAN/GOVERNOR/KEEPER)

    FloatingMarket public floating;
    FixedMarket public fixedM;
    Tranche public senior;
    Tranche public junior;
    Tranche public fSenior;
    Tranche public fJunior;

    // ghosts
    uint256 public ghost_maxBadDebtSeen;
    uint256 public ghost_badDebtRecognized;
    uint256 public ghost_badDebtCovered;
    uint256 public ghost_badDebtRetiredOnRedeem;
    uint256 public ghost_lastSeniorPrice;
    uint256 public ghost_lastJuniorPrice;
    bool public ghost_priceDropWithoutSlash;
    uint256 public ghost_slashCount;
    uint256 public ghost_roundTripExcess; // wei paid out above deposit on immediate round trip
    uint256[] public stableRequestIds;
    mapping(uint256 => address) public stableRequestController;
    uint256[] public fixedLoans;
    uint256 public calls;

    constructor(
        ICapWorld d,
        address[] memory deps,
        address[] memory uws,
        address liq,
        FloatingMarket fl,
        FixedMarket fx,
        Tranche s,
        Tranche j,
        Tranche fs,
        Tranche fj
    ) {
        D = d;
        depositors = deps;
        underwriters = uws;
        liquidator = liq;
        guardian = address(d);
        floating = fl;
        fixedM = fx;
        senior = s;
        junior = j;
        fSenior = fs;
        fJunior = fj;
        ghost_lastSeniorPrice = _price(s);
        ghost_lastJuniorPrice = _price(j);
    }

    // ───── helpers ─────
    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function _price(Tranche t) internal view returns (uint256) {
        return t.totalSupply() == 0 ? 1e18 : t.previewRedeem(1e18);
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
        // collateral price between 0.5 and 1.5 of par, moves in small steps
        bps = _bound(bps, 5000, 15000);
        D.setCollateralPrice(1e18 * bps / 10000);
        _checkPriceMonotone(false);
    }

    // ───── stablecoin depositors ─────
    function stableDeposit(uint256 who, uint256 amount) external count {
        address a = depositors[who % depositors.length];
        amount = _bound(amount, 1e6, 1_000_000e18);
        D.depositStable(a, amount);
        _checkPriceMonotone(false);
    }

    function stableRedeemInstant(uint256 who, uint256 shares) external count {
        address a = depositors[who % depositors.length];
        uint256 max = D.stable().maxRedeem(a);
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        uint256 bd = D.stable().badDebt();
        D.redeemStable(a, shares);
        uint256 bd2 = D.stable().badDebt();
        if (bd > bd2) ghost_badDebtRetiredOnRedeem += bd - bd2;
    }

    /// @dev deposit then immediately redeem the same shares; must never pay out more than put in
    function stableRoundTrip(uint256 who, uint256 amount) external count {
        address a = depositors[who % depositors.length];
        amount = _bound(amount, 1e6, 100_000e18);
        uint256 shares = D.depositStable(a, amount);
        uint256 before = D.underlying().balanceOf(a); // after the mint+deposit: net of this call so far
        uint256 max = D.stable().maxRedeem(a);
        if (max < shares) return; // cannot round-trip; leave the deposit
        uint256 bd = D.stable().badDebt();
        D.redeemStable(a, shares);
        uint256 bd2 = D.stable().badDebt();
        if (bd > bd2) ghost_badDebtRetiredOnRedeem += bd - bd2;
        uint256 after_ = D.underlying().balanceOf(a);
        if (after_ > before + amount) ghost_roundTripExcess += after_ - before - amount;
    }

    function stableRequestRedeem(uint256 who, uint256 shares) external count {
        address a = depositors[who % depositors.length];
        uint256 bal = D.stable().balanceOf(a);
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        uint256 id = D.requestRedeemStable(a, shares);
        stableRequestIds.push(id);
        stableRequestController[id] = a;
    }

    function stableClaim(uint256 idx, uint256 shares) external count {
        if (stableRequestIds.length == 0) return;
        uint256 id = stableRequestIds[idx % stableRequestIds.length];
        address a = stableRequestController[id];
        uint256 max = D.stable().claimableRedeemRequest(id, a);
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        uint256 bd = D.stable().badDebt();
        D.claimStable(a, id, shares);
        uint256 bd2 = D.stable().badDebt();
        if (bd > bd2) ghost_badDebtRetiredOnRedeem += bd - bd2;
    }

    function coverBadDebt(uint256 amount) external count {
        uint256 bd = D.stable().badDebt();
        if (bd == 0) return;
        amount = _bound(amount, 1, bd);
        uint256 covered = D.coverBadDebt(amount);
        ghost_badDebtCovered += covered;
    }

    // ───── underwriters (tranches) ─────
    function trancheDeposit(uint256 who, uint256 which, uint256 amount) external count {
        address a = underwriters[who % underwriters.length];
        Tranche t = _pick(which);
        if (t.killed()) return;
        amount = _bound(amount, 2e3, 500e18);
        D.fundTrancheFor(address(t), a, amount);
        _checkPriceMonotone(false);
    }

    function trancheRedeemInstant(uint256 who, uint256 which, uint256 shares) external count {
        address a = underwriters[who % underwriters.length];
        Tranche t = _pick(which);
        uint256 max;
        try t.maxRedeem(a) returns (uint256 m) {
            max = m;
        }
            catch {
            return;
        }
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        D.redeemTranche(address(t), a, shares);
        _checkPriceMonotone(false);
    }

    function trancheRequestRedeem(uint256 who, uint256 which, uint256 shares) external count {
        address a = underwriters[who % underwriters.length];
        Tranche t = _pick(which);
        uint256 bal = t.balanceOf(a);
        if (bal == 0) return;
        shares = _bound(shares, 1, bal);
        D.requestRedeemTranche(address(t), a, shares);
    }

    function trancheClaim(uint256 who, uint256 which, uint256 id, uint256 shares) external count {
        address a = underwriters[who % underwriters.length];
        Tranche t = _pick(which);
        uint256 n = D.trancheRequestCount(address(t));
        if (n == 0) return;
        id = id % n;
        uint256 max;
        try t.claimableRedeemRequest(id, a) returns (uint256 m) {
            max = m;
        }
            catch {
            return;
        }
        if (max == 0) return;
        shares = _bound(shares, 1, max);
        D.claimTranche(address(t), a, id, shares);
        _checkPriceMonotone(false);
    }

    function trancheClaimPremium(uint256 who, uint256 which) external count {
        address a = underwriters[who % underwriters.length];
        D.claimPremium(address(_pick(which)), a);
    }

    // ───── floating market ─────
    function floatBorrow(uint256 amount) external count {
        uint256 credit = floating.availableCredit();
        if (credit == 0) return;
        amount = _bound(amount, 1, credit);
        D.borrowFloating(amount);
        _checkPriceMonotone(false);
    }

    function floatRepay(uint256 amount) external count {
        floating.chargePremium();
        uint256 debt = floating.totalDebt();
        // WS-A finding A-1: the floating reading can sit a wei above creditBackedSupply; a full
        // repay then underflows in burnCreditBacked. Documented Low; stay off it here.
        uint256 credit = D.stable().creditBackedSupply();
        if (debt > credit) {
            if (credit < 2) return;
            debt = credit - 1;
        }
        uint256 minUnit = floating.index() / 1e27 + 1; // below one scaled unit repay reverts by design
        if (debt < minUnit) return;
        amount = _bound(amount, minUnit, debt);
        D.repayFloating(amount);
    }

    function floatCharge() external count {
        floating.chargePremium();
        _checkPriceMonotone(false);
    }

    function floatLiquidate(uint256 amount) external count {
        if (floating.healthiness() >= 1e27) return;
        uint256 max = floating.maxLiquidatable();
        uint256 minUnit = floating.index() / 1e27 + 1;
        if (max < minUnit) return;
        amount = _bound(amount, minUnit, max);
        _snapPrices();
        D.liquidateFloating(amount);
        ghost_slashCount++;
        _checkPriceMonotone(true);
    }

    function floatWriteOff() external count {
        floating.chargePremium();
        if (floating.unrecoverableDebt() < floating.index() / 1e27 + 1) return; // sub-unit write-off reverts by design
        uint256 bd = D.stable().badDebt();
        D.writeOffFloating();
        ghost_badDebtRecognized += D.stable().badDebt() - bd;
    }

    // ───── fixed market ─────
    function fixedBorrow(uint256 amount, uint256 term) external count {
        term = _bound(term, fixedM.minimumTermLimit(), fixedM.maximumTermLimit());
        uint256 credit = fixedM.availableCredit(term);
        if (credit == 0) return;
        amount = _bound(amount, 1, credit);
        uint256 id = D.borrowFixed(amount, term);
        fixedLoans.push(id);
    }

    function fixedRepay(uint256 idx, uint256 amount) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        uint256 debt = fixedM.debt(id);
        if (debt == 0) return;
        amount = _bound(amount, 1, debt);
        D.repayFixed(id, amount);
    }

    function fixedExtendAdmin(uint256 idx) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        if (fixedM.debt(id) == 0) return;
        if (block.timestamp < fixedM.expiry(id) + fixedM.grace()) return;
        D.extendAdminFixed(id);
    }

    function fixedLiquidate(uint256 idx, uint256 amount) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        if (fixedM.debt(id) == 0) return;
        if (fixedM.healthiness() >= 1e27) return;
        uint256 max = fixedM.maxLiquidatable();
        if (max == 0) return;
        amount = _bound(amount, 1, max < fixedM.debt(id) ? max : fixedM.debt(id));
        D.liquidateFixed(id, amount);
        ghost_slashCount++;
    }

    function fixedWriteOff(uint256 idx) external count {
        if (fixedLoans.length == 0) return;
        uint256 id = fixedLoans[idx % fixedLoans.length];
        if (fixedM.debt(id) == 0 || fixedM.unrecoverableDebt() == 0) return;
        uint256 bd = D.stable().badDebt();
        D.writeOffFixed(id);
        ghost_badDebtRecognized += D.stable().badDebt() - bd;
    }

    function _pick(uint256 which) internal view returns (Tranche) {
        which %= 4;
        if (which == 0) return senior;
        if (which == 1) return junior;
        if (which == 2) return fSenior;
        return fJunior;
    }

    function stableRequestCount() external view returns (uint256) {
        return stableRequestIds.length;
    }

    function fixedLoanCount() external view returns (uint256) {
        return fixedLoans.length;
    }
}
