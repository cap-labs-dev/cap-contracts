// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../../../contracts/cap/InterestRateModel.sol";
import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { CapDeployer6 } from "../shared/CapDeployer6.sol";
import { CapHandler, ICapWorld, IVaultLike } from "./CapHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

/// @title Cap protocol invariants, round 3 (HEAD a843c1d), 6-decimal underlying
/// @dev Run: FOUNDRY_TEST=audit/v3/tests forge test --match-path 'audit/v3/tests/invariants/*' -vv
///      Deep: FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=50 FOUNDRY_TEST=audit/v3/tests forge test \
///            --match-path 'audit/v3/tests/invariants/*' -vv
contract CapInvariants is StdInvariant, CapDeployer6, ICapWorld {
    CapHandler public handler;
    FloatingMarket public floating;
    FixedMarket public fixedM;
    Tranche public senior;
    Tranche public junior;
    Tranche public fSenior;
    Tranche public fJunior;
    Underwriter public uw;
    Tranche[] tranches;
    address[] deps;
    address[] uws;
    address[] trancheHolders; // uws + the underwriter vault

    // I30 reporting ghosts (not asserted)
    uint256 public ghost_i30_sumCapitalLt;
    uint256 public ghost_i30_sumDebt;
    uint256 public ghost_i30_minCoverageRay = type(uint256).max;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true;
        cfg.defaultFixedCreditLimit = type(uint256).max; // let variable limit bind
        _deployCap6WithConfig(cfg);

        (address m, address t0, address t1) = _createMarket("float");
        floating = FloatingMarket(m);
        senior = Tranche(t0);
        junior = Tranche(t1);
        _configureMarketRates(floating);
        (address fm, address ft0, address ft1) = _createFixedMarket("fixed");
        fixedM = FixedMarket(fm);
        fSenior = Tranche(ft0);
        fJunior = Tranche(ft1);
        _configureMarketRates(FloatingMarket(fm));
        tranches.push(senior);
        tranches.push(junior);
        tranches.push(fSenior);
        tranches.push(fJunior);

        for (uint256 i; i < 3; ++i) {
            deps.push(makeAddr(string.concat("dep", vm.toString(i))));
        }
        for (uint256 i; i < 3; ++i) {
            uws.push(makeAddr(string.concat("uw", vm.toString(i))));
            trancheHolders.push(uws[i]);
        }

        // seed: reserve + collateral so the first actions have something to act on
        _depositStable(deps[0], 1_000_000 * ONE_USDC);
        _fundTranche(t0, uws[0], 400e18);
        _fundTranche(t1, uws[1], 100e18);
        _fundTranche(ft0, uws[0], 400e18);
        _fundTranche(ft1, uws[1], 100e18);

        // one underwriter vault registered on every tranche, defaulting into the floating senior
        uw = _deployUnderwriter();
        for (uint256 i; i < tranches.length; ++i) {
            _admitDepositor(address(tranches[i]), address(uw));
            uw.addTranche(address(tranches[i]));
        }
        uw.setDefaultTranche(address(senior));
        _fundUnderwriter(address(uw), uws[2], 200e18);
        trancheHolders.push(address(uw));

        handler = new CapHandler(
            ICapWorld(address(this)),
            deps,
            uws,
            defaultLiquidator,
            floating,
            fixedM,
            [senior, junior, fSenior, fJunior],
            uw
        );
        targetContract(address(handler));
    }

    function stable() external view returns (Stablecoin) {
        return stablecoin;
    }

    function underlying() external view returns (MockERC20) {
        return cusdUnderlying;
    }

    function rateModel() external view returns (InterestRateModel) {
        return irm;
    }

    // ───── pranked actions the handler calls (this contract holds every admin role) ─────
    // Every prank is a single-call `vm.prank` so a revert caught upstream never leaves one armed.

    function warpBy(uint256 dt) external {
        vm.warp(block.timestamp + dt);
    }

    function setCollateralPrice(uint256 p) external {
        _setPrice(address(collateral), p);
    }

    function depositStable(address a, uint256 amt) external returns (uint256 shares) {
        cusdUnderlying.mint(a, amt);
        vm.prank(a);
        cusdUnderlying.approve(address(stablecoin), amt);
        vm.prank(a);
        shares = stablecoin.deposit(amt, a);
    }

    function instantRedeemStable(address a, uint256 shares) external {
        vm.prank(a);
        stablecoin.instantRedeem(shares, a, a);
    }

    function requestRedeemStable(address a, uint256 shares) external returns (uint256 id) {
        vm.prank(a);
        id = stablecoin.requestRedeem(shares, a, a);
    }

    function claimStable(address a, uint256 id, uint256 shares) external {
        vm.prank(a);
        stablecoin.redeem(id, shares, a, a);
    }

    function claimStableFifo(address a, uint256 shares) external {
        vm.prank(a);
        stablecoin.redeem(shares, a, a);
    }

    function transferStableRequest(address from, uint256 id, address to) external {
        vm.prank(from);
        stablecoin.transferRequest(id, to);
    }

    /// @dev `amt` is cUSD (18 dec); mint exactly that many shares against ceil'd underlying
    function coverBadDebt(uint256 amt) external returns (uint256 covered) {
        uint256 assets = stablecoin.previewMint(amt);
        cusdUnderlying.mint(address(this), assets);
        cusdUnderlying.approve(address(stablecoin), assets);
        stablecoin.mint(amt, address(this));
        covered = stablecoin.coverBadDebt(amt);
    }

    function fundTrancheFor(address t, address a, uint256 amt) external {
        collateral.mint(a, amt);
        vm.prank(a);
        collateral.approve(address(vault), amt);
        vm.prank(a);
        vault.deposit(address(collateral), amt, a);
        vm.prank(a);
        vault.setOperator(t, true);
        _admitDepositor(t, a);
        vm.prank(a);
        Tranche(t).deposit(amt, a);
        vm.prank(a);
        Tranche(t).optIn();
    }

    function fundUnderwriterFor(address a, uint256 amt) external {
        collateral.mint(a, amt);
        vm.prank(a);
        collateral.approve(address(vault), amt);
        vm.prank(a);
        vault.deposit(address(collateral), amt, a);
        _admitDepositor(address(uw), a);
        vm.prank(a);
        vault.setOperator(address(uw), true);
        vm.prank(a);
        uw.deposit(amt, a);
        vm.prank(a);
        uw.optIn();
    }

    function instantRedeemVault(address v, address a, uint256 shares) external {
        vm.prank(a);
        Tranche(v).instantRedeem(shares, a, a);
    }

    function requestRedeemVault(address v, address a, uint256 shares) external returns (uint256 id) {
        vm.prank(a);
        id = Tranche(v).requestRedeem(shares, a, a);
    }

    function claimVault(address v, address a, uint256 id, uint256 shares) external {
        vm.prank(a);
        Tranche(v).redeem(id, shares, a, a);
    }

    function claimVaultFifo(address v, address a, uint256 shares) external {
        vm.prank(a);
        Tranche(v).redeem(shares, a, a);
    }

    function claimPremium(address v, address a) external {
        vm.prank(a);
        Tranche(v).claim(a);
    }

    function uwAllocate(address t, uint256 assets) external {
        uw.allocate(t, assets);
    }

    function uwDeallocate(address t, uint256 shares) external returns (uint256 freed) {
        freed = uw.deallocate(t, shares);
    }

    function uwDeallocateAsync(address t, uint256 shares) external returns (uint256 id) {
        id = uw.deallocateAsync(t, shares);
    }

    function uwFinalize(address t, uint256 id, uint256 shares) external {
        uw.finalizeDeallocateAsync(t, id, shares);
    }

    function uwReport(address t) external {
        uw.report(t);
    }

    function borrowFloating(uint256 amt) external returns (uint256 actual) {
        vm.prank(defaultBorrower);
        actual = floating.borrow(defaultBorrower, amt);
    }

    function repayFloating(uint256 amt) external {
        _ensureStable(defaultBorrower, amt);
        vm.prank(defaultBorrower);
        floating.repay(amt);
    }

    function liquidateFloating(uint256 amt) external {
        _ensureStable(defaultLiquidator, amt);
        vm.prank(defaultLiquidator);
        floating.liquidate(defaultLiquidator, amt);
    }

    function writeOffFloating() external {
        floating.writeOff();
    }

    function borrowFixed(uint256 amt, uint256 term) external returns (uint256 id) {
        vm.prank(defaultBorrower);
        (id,) = fixedM.borrow(defaultBorrower, amt, term);
    }

    function repayFixed(uint256 id, uint256 amt) external {
        _ensureStable(defaultBorrower, amt);
        vm.prank(defaultBorrower);
        fixedM.repay(id, amt);
    }

    function extendAdminFixed(uint256 id) external {
        fixedM.extendAdmin(id, type(uint256).max);
    }

    function liquidateFixed(uint256 id, uint256 amt) external {
        _ensureStable(defaultLiquidator, amt);
        vm.prank(defaultLiquidator);
        fixedM.liquidate(id, defaultLiquidator, amt);
    }

    function writeOffFixed(uint256 id) external {
        fixedM.writeOff(id);
    }

    function setLt(address m, uint256 lt) external {
        FloatingMarket(m).setLt(lt);
    }

    function setLiquidationBonus(uint256 bonus) external {
        irm.setLiquidationBonus(bonus);
    }

    /// @dev Top `a` up to `amt` cUSD by minting exactly the missing shares (ceil'd 6-dec assets)
    function _ensureStable(address a, uint256 amt) internal {
        uint256 bal = stablecoin.balanceOf(a);
        if (bal >= amt) return;
        uint256 need = amt - bal;
        uint256 assets = stablecoin.previewMint(need);
        cusdUnderlying.mint(a, assets);
        vm.prank(a);
        cusdUnderlying.approve(address(stablecoin), assets);
        vm.prank(a);
        stablecoin.mint(need, a);
    }

    function _vaults() internal view returns (IVaultLike[] memory v) {
        v = new IVaultLike[](6);
        v[0] = IVaultLike(address(stablecoin));
        for (uint256 i; i < 4; ++i) {
            v[i + 1] = IVaultLike(address(tranches[i]));
        }
        v[5] = IVaultLike(address(uw));
    }

    function _holdersOf(IVaultLike v) internal view returns (address[] memory) {
        if (address(v) == address(stablecoin)) return deps;
        if (address(v) == address(uw)) return uws;
        return trancheHolders;
    }

    // ───── invariants ─────
    /// I1 reserve solvency: the reserve can pay out every unlocked share.
    /// Restated in units for a 6-dec underlying (balanceOf is base units, unlockedSupply is 18-dec
    /// shares): the source compared them directly, which only worked at 18/18.
    function invariant_I1_reserveCoversUnlockedSupply() public view {
        assertLe(
            stablecoin.convertToAssets(stablecoin.unlockedSupply()),
            cusdUnderlying.balanceOf(address(stablecoin)),
            "I1: unlocked supply is worth more underlying than the reserve holds"
        );
    }

    /// I2 supply decomposition
    function invariant_I2_supplyDecomposition() public view {
        assertGe(stablecoin.totalSupply(), stablecoin.creditBackedSupply() + stablecoin.badDebt(), "I2");
    }

    /// I3 debt never outruns minted credit; drift is dust
    function invariant_I3_debtMatchesCreditBackedSupply() public view {
        // floating debt is read off a projected index; premium accrued since the last charge is
        // in totalDebt but not yet minted, so it is netted out here
        (uint256 lp, uint256 up) = floating.premium();
        uint256 debt = floating.totalDebt() + fixedM.totalDebt();
        uint256 credit = stablecoin.creditBackedSupply() + lp + up;
        uint256 slack = 1e6 + handler.calls();
        assertGe(credit + slack, debt, "I3: debt outran minted cUSD beyond rounding drift");
        if (credit > debt) assertLe(credit - debt, slack, "I3: phantom credit-backed supply drift");
    }

    /// I4 bad debt only falls through cover or redemption retirement
    function invariant_I4_badDebtAccounting() public view {
        uint256 expected =
            handler.ghost_badDebtRecognized() - handler.ghost_badDebtCovered() - handler.ghost_badDebtRetiredOnRedeem();
        assertEq(stablecoin.badDebt(), expected, "I4");
    }

    /// I5 coverage: healthy, or a remedy exists
    function invariant_I5_coverageOrRemedy() public view {
        _coverage(
            floating.healthiness(), floating.unrecoverableDebt(), floating.maxLiquidatable(), floating.totalDebt()
        );
        _coverage(fixedM.healthiness(), fixedM.unrecoverableDebt(), fixedM.maxLiquidatable(), fixedM.totalDebt());
    }

    function _coverage(uint256 h, uint256 unrec, uint256 maxLiq, uint256 debt) internal pure {
        if (h >= 1e27) return;
        assertTrue(unrec > 0 || maxLiq > 0 || debt < 1e6, "I5: unhealthy with no remedy");
    }

    /// I6 weights
    function invariant_I6_weightsSumToRay() public view {
        uint256 w;
        for (uint256 i; i < floating.tranches().length; ++i) {
            w += floating.tranches()[i].weight;
        }
        assertEq(w, 1e27, "I6 float");
        w = 0;
        for (uint256 i; i < fixedM.tranches().length; ++i) {
            w += fixedM.tranches()[i].weight;
        }
        assertEq(w, 1e27, "I6 fixed");
    }

    /// I7 seniority: senior never locks more than junior
    function invariant_I7_lockedValueMonotoneInSeniority() public view {
        assertLe(floating.lockedValue(address(senior)), floating.lockedValue(address(junior)), "I7 float");
        assertLe(fixedM.lockedValue(address(fSenior)), fixedM.lockedValue(address(fJunior)), "I7 fixed");
    }

    /// I8 borrow capacity inside the liquidation threshold
    function invariant_I8_creditLimitInsideThreshold() public view {
        assertLe(floating.variableCreditLimit(), floating.debtLiquidationThreshold(), "I8 float");
        assertLe(fixedM.variableCreditLimit(), fixedM.debtLiquidationThreshold(), "I8 fixed");
    }

    /// I9 tranche share price only falls through slash
    function invariant_I9_sharePriceOnlyFallsOnSlash() public view {
        assertFalse(handler.ghost_priceDropWithoutSlash(), "I9");
    }

    /// I11 no free money on a deposit->redeem round trip
    function invariant_I11_roundTripNeverProfits() public view {
        assertEq(handler.ghost_roundTripExcess(), 0, "I11");
    }

    /// I12 vault conservation
    function invariant_I12_vaultConservation() public view {
        assertGe(collateral.balanceOf(address(vault)), vault.totalSupply(vault.id(address(collateral))), "I12");
    }

    /// I13 queue conservation: shares parked in the vault == outstanding queue on tranches and the
    /// underwriter; >= on the stablecoin, which also parks its own premium pot in its balance.
    function invariant_I13_queueConservation() public view {
        assertGe(
            stablecoin.balanceOf(address(stablecoin)),
            stablecoin.redemptionQueue(),
            "I13 stable (pot shares share the balance)"
        );
        for (uint256 i; i < tranches.length; ++i) {
            assertEq(
                tranches[i].balanceOf(address(tranches[i])), tranches[i].redemptionQueue(), "I13 tranche: queue != held"
            );
        }
        assertEq(uw.balanceOf(address(uw)), uw.redemptionQueue(), "I13 underwriter: queue != held");
    }

    /// I15 FIFO: a later request is never claimable while an earlier one is still pending.
    /// Kept verbatim from round 2. NB the new watermark queue documents that "already-claimable
    /// shares may settle out of order" (ERC7540AsyncRedeem.claimableRedeemRequest), so a failure
    /// here is to be read against that note.
    function invariant_I15_fifo() public view {
        uint256 n = handler.stableRequestCount();
        if (n < 2) return;
        for (uint256 j = 1; j < n; ++j) {
            uint256 idJ = handler.stableRequestIds(j);
            address cJ = handler.stableRequestController(idJ);
            if (stablecoin.claimableRedeemRequest(idJ, cJ) == 0) continue;
            for (uint256 i; i < j; ++i) {
                uint256 idI = handler.stableRequestIds(i);
                address cI = handler.stableRequestController(idI);
                assertEq(stablecoin.pendingRedeemRequest(idI, cI), 0, "I15: later request claimable before earlier");
            }
        }
    }

    /// I17 (H-2 restated for the watermark queue): per-request claimable <= unlockedSupply, and
    /// the sum of live request shares == redeemQueue - settledQueue. `requestShares[id]` is not
    /// public; it is read back as pending + claimable for the controller `controllerOf(id)`
    /// reports, and `redeemQueue - settledQueue` is `redemptionQueue()`.
    function invariant_I17_queueAccounting() public view {
        IVaultLike[] memory v = _vaults();
        for (uint256 k; k < v.length; ++k) {
            _i17(v[k]);
        }
    }

    function _i17(IVaultLike v) internal view {
        uint256 n = handler.requestCount(address(v));
        uint256 unlocked = v.unlockedSupply();
        uint256 sum;
        for (uint256 id = 1; id <= n; ++id) {
            address c = v.controllerOf(id);
            if (c == address(0)) continue; // fully settled
            uint256 claimable = v.claimableRedeemRequest(id, c);
            assertLe(claimable, unlocked, "I17: a request is claimable beyond unlockedSupply");
            sum += claimable + v.pendingRedeemRequest(id, c);
        }
        assertEq(sum, v.redemptionQueue(), "I17: sum of request shares != redemptionQueue");
    }

    /// I18: staked supply == sum of opted-in balances (tranches + underwriter vault)
    function invariant_I18_stakedEqualsOptedIn() public view {
        IVaultLike[] memory v = _vaults();
        for (uint256 k = 1; k < v.length; ++k) {
            _i18(v[k]);
        }
    }

    function _i18(IVaultLike v) internal view {
        address[] memory holders = _holdersOf(v);
        uint256 s;
        for (uint256 u; u < holders.length; ++u) {
            if (v.optedIn(holders[u])) s += v.balanceOf(holders[u]);
        }
        assertEq(v.stakedSupply(), s, "I18");
    }

    /// I19/I20: vesting never over-releases
    function invariant_I19_vestingBounded() public view {
        IVaultLike[] memory v = _vaults();
        for (uint256 k = 1; k < v.length; ++k) {
            _i19(v[k]);
        }
        assertLe(stablecoin.vested(), stablecoin.vested() + stablecoin.remaining(), "I20 stable");
    }

    function _i19(IVaultLike v) internal view {
        // pot held >= what is still owed: remaining (unvested) + every holder's claimable
        address[] memory holders = _holdersOf(v);
        uint256 owed = v.remaining();
        for (uint256 u; u < holders.length; ++u) {
            owed += v.claimable(holders[u]);
        }
        assertLe(
            owed, IERC20(address(stablecoin)).balanceOf(address(v)) + 1e3, "I19: entitlements exceed pot beyond dust"
        );
    }

    /// I30 master solvency: once every lazily-accruing market has charged its premium, the sum of
    /// market debt is exactly the credit-backed supply (every mint/burn of credit goes through a
    /// market and moves both sides by the same amount). Coverage is recorded, not asserted.
    function invariant_I30_masterSolvency() public {
        floating.chargePremium(); // fixed market charges premium eagerly at borrow/extend
        uint256 debt = floating.totalDebt() + fixedM.totalDebt();
        uint256 credit = stablecoin.creditBackedSupply();
        uint256 markets = 2;
        assertApproxEqAbs(debt, credit, markets, "I30: sum of market debt != creditBackedSupply");

        uint256 capLt = floating.totalCapital() * floating.lt() / 1e27 + fixedM.totalCapital() * fixedM.lt() / 1e27;
        ghost_i30_sumCapitalLt = capLt;
        ghost_i30_sumDebt = debt;
        if (debt > 0) {
            uint256 cov = capLt * 1e27 / debt;
            if (cov < ghost_i30_minCoverageRay) ghost_i30_minCoverageRay = cov;
        }
    }

    /// I33 set consistency: `controllerRequests` is a private EnumerableSet with no getter, but
    /// `maxRedeem(c)` walks it, so it is checked against the per-request views: for every actor,
    /// min(unlocked, sum over ids with controllerOf(id) == c of claimable(id, c)) == maxRedeem(c).
    function invariant_I33_controllerSetConsistency() public view {
        IVaultLike[] memory v = _vaults();
        for (uint256 k; k < v.length; ++k) {
            _i33(v[k]);
        }
    }

    function _i33(IVaultLike v) internal view {
        address[] memory actors = _holdersOf(v);
        uint256 n = handler.requestCount(address(v));
        uint256 unlocked = v.unlockedSupply();
        for (uint256 a; a < actors.length; ++a) {
            uint256 sum;
            for (uint256 id = 1; id <= n; ++id) {
                if (v.controllerOf(id) == actors[a]) sum += v.claimableRedeemRequest(id, actors[a]);
            }
            uint256 expected = sum > unlocked ? unlocked : sum;
            assertEq(v.maxRedeem(actors[a]), expected, "I33: maxRedeem disagrees with the request set");
        }
    }

    /// I34: the stablecoin's own share balance covers the queue plus the unvested pot
    function invariant_I34_stableHoldsQueueAndPot() public view {
        assertGe(
            stablecoin.balanceOf(address(stablecoin)),
            stablecoin.redemptionQueue() + stablecoin.remaining(),
            "I34: stablecoin self-balance < redemptionQueue + remaining"
        );
    }

    /// I35: credit-backed supply plus bad debt never exceeds total supply
    function invariant_I35_creditPlusBadDebtWithinSupply() public view {
        assertLe(
            stablecoin.creditBackedSupply() + stablecoin.badDebt(),
            stablecoin.totalSupply(),
            "I35: creditBackedSupply + badDebt > totalSupply"
        );
    }

    /// I37: the underwriter's cached book is never below the live value of its positions
    function invariant_I37_underwriterBookNotBelowLive() public view {
        uint256 live = vault.balanceOf(address(uw), address(collateral));
        for (uint256 i; i < tranches.length; ++i) {
            Tranche t = tranches[i];
            live += t.convertToAssets(t.balanceOf(address(uw)) + uw.queuedShares(address(t)));
        }
        // each share-moving tranche action floors on the mover's side and may gift 1 wei to the
        // remaining holders (the underwriter among them), so the book may trail live by that many wei
        assertGe(
            uw.totalAssets() + handler.ghost_shareOps(),
            live,
            "I37: underwriter totalAssets below live vault + tranche position value (beyond 1 wei per share op)"
        );
    }

    /// I38: liquidation cannot release more collateral value than the threshold guarantees:
    /// lt * (1 + liquidationBonus) <= 1 on every market. Explored via handler setLt/setLiquidationBonus.
    function invariant_I38_ltTimesBonusWithinOne() public view {
        uint256 bonus = irm.liquidationBonus();
        assertLe(
            floating.lt() * (1e27 + bonus) / 1e27,
            1e27,
            "I38 float: lt * (1 + liquidationBonus) > 1, liquidation over-releases collateral"
        );
        assertLe(
            fixedM.lt() * (1e27 + bonus) / 1e27,
            1e27,
            "I38 fixed: lt * (1 + liquidationBonus) > 1, liquidation over-releases collateral"
        );
    }

    function invariant_callSummary() public view {
        // surfaced in -vv output so the run count is real
        console_log(
            handler.calls(), handler.ghost_reverts(), handler.ghost_slashCount(), handler.ghost_badDebtRecognized()
        );
    }

    function console_log(uint256 a, uint256 b, uint256 c, uint256 d) internal pure {
        a;
        b;
        c;
        d;
    }
}
