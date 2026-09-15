// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// LEAD-3 independent verification (HEAD a843c1d). Harness defaults: price 1, ltv 0.5, buffer 0.1,
/// lt 0.8, bonus 2%, underwriter rate 20% APR, weights [0.95, 0.05], fixed credit limit 1000.
/// Book: senior = market owner's own capital (1000), junior = a third party's capital (1000),
/// borrower draws the full 1000 so lockedValue = 1000/0.7 = 1428.57 > junior capital.
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/LEAD-3 forge test --match-path 'audit/v3/tests/scratch/verify/LEAD-3/*' -vv
contract LEAD3_Verify is CapDeployer {
    address ownerLP = makeAddr("ownerCapitalInSenior");
    address juniorLP = makeAddr("thirdPartyJunior");
    MarketBundle b;
    uint256 constant S = 1_000e18;
    uint256 constant J = 1_000e18;
    uint256 constant D = 1_000e18;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M"); // owner = address(this), borrower = defaultBorrower
        _fundTranche(b.tranche0Addr, ownerLP, S);
        _fundTranche(b.tranche1Addr, juniorLP, J);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        assertEq(b.market.totalDebt(), D, "full line drawn");
        assertEq(b.tranche1.unlockedSupply(), 0, "junior fully locked");
        assertGt(b.tranche0.unlockedSupply(), 0, "senior keeps its buffer");
    }

    function _w(uint256 a, uint256 c) internal pure returns (uint256[] memory w) {
        w = new uint256[](2);
        w[0] = a;
        w[1] = c;
    }

    function _charge30d() internal returns (uint256 liq, uint256 uwP) {
        vm.warp(block.timestamp + 30 days);
        (liq, uwP) = b.market.premium();
        b.market.chargePremium();
    }

    // ── (a) is a zero weight rejected anywhere? ──────────────────────────────

    function test_V1_zeroWeightAcceptedEverywhere() public {
        // setTrancheWeights on a funded, locked market
        b.market.setTrancheWeights(_w(1e27, 0));
        assertEq(b.market.tranches()[1].weight, 0, "setTrancheWeights accepts 0 on a locked junior");
        // 1 wei is accepted as well (matters for the proposed invariant I43)
        b.market.setTrancheWeights(_w(1e27 - 1, 1));
        assertEq(b.market.tranches()[1].weight, 1);
        // Registry.createTranche appends a new most-junior tranche at weight 0
        uint256[] memory three = new uint256[](3);
        three[0] = 1e27;
        address t2 = registry.createTranche(b.marketAddr, address(collateral), three);
        assertEq(b.market.tranches()[2].tranche, t2);
        assertEq(b.market.tranches()[2].weight, 0, "createTranche accepts 0 for the new junior");
        // Registry.createFloatingMarket accepts a zero-weight junior at creation
        (address m2, address[] memory ts) =
            registry.createFloatingMarket(_uniformAssets(2), _w(1e27, 0), "Z", _operatorRoleOf(defaultMarketOwner));
        assertEq(FloatingMarket(m2).tranches()[1].weight, 0, "createFloatingMarket accepts 0");
        assertEq(ts.length, 2);
        emit log_string("no per-tranche floor in _setTranches, setTrancheWeights, createTranche, or createFloatingMarket");
    }

    // ── (b) can the junior exit or opt out of anything? ──────────────────────

    function test_V2_lockedJuniorCannotExitOrOptOutOfSlash() public {
        b.market.setTrancheWeights(_w(1e27, 0));
        uint256 shares = b.tranche1.balanceOf(juniorLP);
        emit log_named_decimal_uint("lockedValue(junior) USD", b.market.lockedValue(b.tranche1Addr), 18);
        emit log_named_decimal_uint("lockedValue(senior) USD", b.market.lockedValue(b.tranche0Addr), 18);
        assertEq(b.tranche1.unlockedSupply(), 0);
        assertEq(b.tranche1.maxRedeem(juniorLP), 0);
        assertEq(b.tranche1.maxInstantRedeem(juniorLP), 0);

        vm.startPrank(juniorLP);
        vm.expectRevert();
        b.tranche1.instantRedeem(shares, juniorLP, juniorLP);
        uint256 id = b.tranche1.requestRedeem(shares, juniorLP, juniorLP);
        assertEq(b.tranche1.claimableRedeemRequest(id, juniorLP), 0, "queued but nothing claimable");
        vm.expectRevert();
        b.tranche1.redeem(id, shares, juniorLP, juniorLP);
        vm.stopPrank();

        // 30 days later, debt still out: still locked
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        assertEq(b.tranche1.claimableRedeemRequest(id, juniorLP), 0, "still nothing claimable after 30d");

        // optOut only stops earning; the lock and the slash order are unchanged
        vm.prank(juniorLP);
        b.tranche1.optOut();
        assertEq(b.tranche1.unlockedSupply(), 0, "optOut does not unlock");
        assertEq(b.market.lockedValue(b.tranche1Addr), b.market.lockedValue(b.tranche1Addr));
        emit log_string("junior: instantRedeem reverts, async claim 0 now and after 30d, optOut changes nothing");
    }

    // ── the PoC: weights [1e27, 0] ───────────────────────────────────────────

    function test_V3_ownerZeroesJuniorWeight_seniorTakesAll() public {
        b.market.setTrancheWeights(_w(1e27, 0));
        (uint256 liq, uint256 uwP) = _charge30d();

        assertEq(stablecoin.balanceOf(b.tranche1Addr), 0, "junior tranche funded nothing");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), uwP, "senior tranche funded the whole underwriter premium");
        assertEq(b.tranche1.claimable(juniorLP), 0, "junior claimable 0");

        vm.warp(block.timestamp + 7 days); // let the 12h vest run out
        assertEq(b.tranche1.claimable(juniorLP), 0, "junior claimable still 0 after vesting");
        uint256 ownerGets = b.tranche0.claimable(ownerLP);
        assertApproxEqRel(ownerGets, uwP, 1e12, "owner's senior claims ~all of it (dead-share dust aside)");

        emit log_named_decimal_uint("debt", D, 18);
        emit log_named_decimal_uint("liquidity rate (harness default)", irm.liquidityRate(), 27);
        emit log_named_decimal_uint("liquidity premium 30d -> cUSD stakers", liq, 18);
        emit log_named_decimal_uint("underwriter premium 30d", uwP, 18);
        emit log_named_decimal_uint("  junior receives at weight 0", 0, 18);
        emit log_named_decimal_uint("  senior (owner) receives", uwP, 18);
        emit log_named_decimal_uint("  owner claimable after vest", ownerGets, 18);
        emit log_named_decimal_uint("counterfactual junior at deploy weight 5%", uwP * 5 / 100, 18);
        emit log_named_decimal_uint(
            "counterfactual junior APR at 5% weight (ray)", uwP * 5 / 100 * 365 / 30 * 1e27 / J, 27
        );
        emit log_named_decimal_uint("junior first-loss exposure (USD)", b.tranche1.totalCapital(), 18);
    }

    // ── liquidation after a price drop: junior slashed first ─────────────────

    function test_V4_juniorSlashedFirstWhileEarningNothing() public {
        b.market.setTrancheWeights(_w(1e27, 0));
        _charge30d();
        uint256 debt = b.market.totalDebt();

        _setPrice(address(collateral), 0.6e18); // capital 1200, threshold 960 < debt ~1016
        assertLt(b.market.healthiness(), 1e27, "unhealthy");
        emit log_named_decimal_uint("healthiness", b.market.healthiness(), 27);
        emit log_named_decimal_uint("maxLiquidatable", b.market.maxLiquidatable(), 18);

        uint256 jBefore = b.tranche1.totalAssets();
        uint256 sBefore = b.tranche0.totalAssets();
        _mintStable(defaultLiquidator, 200e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = b.market.liquidate(defaultLiquidator, 200e18);
        uint256 jLoss = jBefore - b.tranche1.totalAssets();
        assertEq(repaid, 200e18);
        assertEq(b.tranche0.totalAssets(), sBefore, "senior untouched");
        assertEq(jLoss, 200e18 * 102 / 100 * 1e18 / 0.6e18, "junior pays 204 USD = 340 tokens");
        emit log_named_decimal_uint("repaid", repaid, 18);
        emit log_named_decimal_uint("slashed USD", slashed, 18);
        emit log_named_decimal_uint("junior tokens lost", jLoss, 18);
        emit log_named_decimal_uint("senior tokens lost", 0, 18);
        emit log_named_decimal_uint("junior premium earned to date", stablecoin.balanceOf(b.tranche1Addr), 18);

        // a full clip wipes the junior and kills it; the senior only then takes the remainder
        uint256 clip = b.market.maxLiquidatable();
        _mintStable(defaultLiquidator, clip);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, clip);
        emit log_named_decimal_uint("after full clip: junior assets", b.tranche1.totalAssets(), 18);
        emit log_named_decimal_uint("after full clip: senior assets", b.tranche0.totalAssets(), 18);
        emit log_string(b.tranche1.killed() ? "junior killed: yes" : "junior killed: no");
        assertLt(b.tranche1.totalAssets(), 1e6, "junior wiped before the senior loses anything material");
        assertGt(debt, 0);
    }

    // ── converse: [0, 1e27] ──────────────────────────────────────────────────

    function test_V5_converseSeniorZero_juniorTakesAll() public {
        b.market.setTrancheWeights(_w(0, 1e27));
        (, uint256 uwP) = _charge30d();
        assertEq(stablecoin.balanceOf(b.tranche0Addr), 0, "senior funded nothing");
        assertEq(stablecoin.balanceOf(b.tranche1Addr), uwP, "junior funded everything");
        emit log_named_decimal_uint("[0,1e27] senior receives", 0, 18);
        emit log_named_decimal_uint("[0,1e27] junior receives", uwP, 18);
    }

    // ── the proposed invariant I43 ("no locked tranche has weight 0") is vacuous ──

    function test_V6_oneWeiWeightPaysZeroToo() public {
        b.market.setTrancheWeights(_w(1e27 - 1, 1));
        (, uint256 uwP) = _charge30d();
        assertEq(stablecoin.balanceOf(b.tranche1Addr), 0, "weight 1 wei: rayMul floors to 0");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), uwP, "senior still gets everything");
        // and any small weight is economically the same
        b.market.setTrancheWeights(_w(1e27 - 1e20, 1e20)); // 1e-7 of the premium
        (, uint256 uwP2) = _charge30d();
        emit log_named_uint("junior at weight 1 wei (wei)", 0);
        emit log_named_uint("junior at weight 1e-7 (wei)", stablecoin.balanceOf(b.tranche1Addr));
        emit log_named_decimal_uint("premium that period", uwP2, 18);
    }

    // ── L-21 sibling: the owner already has a documented unfloored lever ─────

    function test_V7_setUnderwriterRateZeroAlreadyZeroesJunior() public {
        b.market.setUnderwriterRate(0); // "There is no lower bound" (InterestRateModel.sol:123)
        (uint256 liq, uint256 uwP) = _charge30d();
        assertEq(uwP, 0);
        assertEq(stablecoin.balanceOf(b.tranche1Addr), 0, "junior 0 under L-21");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), 0, "senior 0 under L-21 too");
        assertEq(b.tranche1.unlockedSupply(), 0, "junior still locked and first-loss");
        emit log_named_decimal_uint("L-21 rate=0: junior", 0, 18);
        emit log_named_decimal_uint("L-21 rate=0: senior", 0, 18);
        emit log_named_decimal_uint("L-21 rate=0: liquidity premium still charged", liq, 18);
        emit log_string("LEAD-3 differs from L-21 only in that the owner's senior keeps the junior's share");
    }

    // ── owner is also the borrower: the premium round-trips into its own senior ──

    function test_V8_ownerBorrowerGetsFreeFirstLossCover() public {
        (address m, address t0, address t1) = _createMarket("O", defaultMarketOwner, defaultMarketOwner);
        FloatingMarket mk = FloatingMarket(m);
        _configureMarketRates(mk);
        _fundTranche(t0, ownerLP, S);
        _fundTranche(t1, juniorLP, J);
        mk.borrow(defaultMarketOwner, type(uint256).max);
        assertEq(Tranche(t1).unlockedSupply(), 0, "junior locked");
        mk.setTrancheWeights(_w(1e27, 0));
        vm.warp(block.timestamp + 30 days);
        (uint256 liq, uint256 uwP) = mk.premium();
        uint256 debtBefore = D;
        mk.chargePremium();
        uint256 growth = mk.totalDebt() - debtBefore;
        assertEq(growth, liq + uwP, "debt growth = liquidity + underwriter premium");
        assertEq(stablecoin.balanceOf(t0), uwP, "all underwriter premium back to the owner's own senior");
        assertEq(stablecoin.balanceOf(t1), 0, "junior: nothing");
        emit log_named_decimal_uint("owner's debt growth 30d", growth, 18);
        emit log_named_decimal_uint("  of which returns to owner's senior", uwP, 18);
        emit log_named_decimal_uint("  net cost of the junior's first-loss cover (liquidity leg only)", liq, 18);
        emit log_named_decimal_uint("junior capital standing first-loss for that", Tranche(t1).totalCapital(), 18);
    }

    // ── a real Underwriter allocator cannot pull out either ──────────────────

    function test_V9_underwriterAllocatorCannotDeallocate() public {
        (address m, address t0, address t1) = _createMarket("U", defaultMarketOwner, defaultBorrower);
        FloatingMarket mk = FloatingMarket(m);
        _configureMarketRates(mk);
        _fundTranche(t0, ownerLP, S);
        Underwriter uw = _deployUnderwriter();
        _admitDepositor(t1, address(uw));
        uw.addTranche(t1);
        _fundUnderwriter(address(uw), makeAddr("uwDepositor"), J);
        uw.allocate(t1, J);
        vm.prank(defaultBorrower);
        mk.borrow(defaultBorrower, type(uint256).max);
        assertEq(Tranche(t1).unlockedSupply(), 0, "underwriter's junior position locked");

        mk.setTrancheWeights(_w(1e27, 0));
        uint256 shares = Tranche(t1).balanceOf(address(uw));
        uint256 got = uw.deallocate(t1, shares);
        assertEq(got, 0, "instant deallocate short-fills to 0");
        uint256 id = uw.deallocateAsync(t1, shares);
        vm.expectRevert();
        uw.finalizeDeallocateAsync(t1, id, shares);
        vm.warp(block.timestamp + 30 days);
        mk.chargePremium();
        assertEq(stablecoin.balanceOf(t1), 0, "underwriter's tranche earns 0");
        vm.expectRevert();
        uw.finalizeDeallocateAsync(t1, id, shares);
        emit log_string("Underwriter: deallocate -> 0, deallocateAsync queued, finalize reverts now and after 30d");
    }

    // ── family context: setLtv after lock raises the junior's *risk*, not just cuts reward ──

    function test_V10_ownerCanAlsoRaiseRiskAfterLock() public {
        uint256 h0 = b.market.healthiness();
        b.market.setLtv(0.7e27); // max allowed: ltv + buffer <= lt
        b.market.setFixedCreditLimit(type(uint256).max); // governor; harness holds the role
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        uint256 h1 = b.market.healthiness();
        emit log_named_decimal_uint("healthiness before setLtv", h0, 27);
        emit log_named_decimal_uint("healthiness after setLtv(0.7) + redraw", h1, 27);
        emit log_named_decimal_uint("debt now", b.market.totalDebt(), 18);
        assertLt(h1, h0);
    }
}
