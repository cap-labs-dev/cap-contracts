// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../../contracts/cap/InterestRateModel.sol";
import { IInterestRateModel } from "../../../contracts/interfaces/IInterestRateModel.sol";
import { CapRoles } from "../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockUtilizationSource } from "../../shared/mocks/MockUtilizationSource.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract InterestRateModelTest is BaseTest {
    InterestRateModel internal irm;
    MockUtilizationSource internal stablecoin;
    address internal market = makeAddr("market");

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpAccessManager();
        stablecoin = new MockUtilizationSource();

        InterestRateModel impl = new InterestRateModel();
        irm = InterestRateModel(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    InterestRateModel.initialize,
                    (address(accessManager), address(stablecoin), 0.5e27, 2e27, 1e27, 0.02e27, 1 hours)
                )
            )
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IInterestRateModel.updateUnderwriterRate.selector;
        accessManager.setTargetFunctionRole(address(irm), selectors, CapRoles.MARKET);
        accessManager.grantRole(CapRoles.MARKET, market, 0);
    }

    function _liquiditySlopes() internal pure returns (IInterestRateModel.Slopes memory s) {
        s = IInterestRateModel.Slopes({ base: 0, slope0: 0.1e27, slope1: 0.9e27, kink: 0.8e27 });
    }

    function test_averageSupplies_tracksTheSource() public {
        stablecoin.setSupplyUtilization(0.5e27);
        irm.updateLiquidityRate();
        skip(365 days);
        (uint256 credit, uint256 supply) = irm.averageSupplies();
        assertGt(credit, 0);
        assertGt(supply, 0);
    }

    function test_setLiquidationBonus_updatesAndBounds() public {
        irm.setLiquidationBonus(0.05e27);
        assertEq(irm.liquidationBonus(), 0.05e27);

        vm.expectRevert(IInterestRateModel.InvalidLiquidationBonus.selector);
        irm.setLiquidationBonus(0.1e27 + 1);

        vm.prank(stranger);
        vm.expectRevert();
        irm.setLiquidationBonus(0.01e27);
    }

    function test_initialLiquidityIndexIsRay() public view {
        (uint256 rate, uint256 index,) = irm.liquidityData();
        assertEq(rate, 0);
        assertEq(index, RAY);
        assertEq(irm.underwriterIndex(market), RAY);
    }

    function test_setLiquiditySlopes_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        irm.setLiquiditySlopes(_liquiditySlopes());
    }

    function test_liquidityRate_atKink() public {
        irm.setLiquiditySlopes(_liquiditySlopes());
        stablecoin.setSupplyUtilization(0.8e27);
        irm.updateLiquidityRate();
        assertEq(irm.liquidityRate(), 0.1e27);
    }

    function test_liquidityRate_aboveKink() public {
        irm.setLiquiditySlopes(_liquiditySlopes());
        stablecoin.setSupplyUtilization(0.9e27);
        irm.updateLiquidityRate();
        assertEq(irm.liquidityRate(), 0.55e27);
    }

    function test_liquidityIndex_growsOverTime() public {
        irm.setLiquiditySlopes(_liquiditySlopes());
        stablecoin.setSupplyUtilization(0.8e27);
        irm.updateLiquidityRate();
        uint256 before = irm.liquidityIndex();
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.liquidityIndex(), before);
    }

    function test_updateUnderwriterRate_fromMarket() public {
        vm.prank(market);
        irm.updateUnderwriterRate(0.2e27);
        assertEq(irm.underwriterRate(market), 0.2e27);
        assertEq(irm.underwriterIndex(market), RAY);
    }

    function test_underwriterIndex_growsOverTime() public {
        vm.prank(market);
        irm.updateUnderwriterRate(0.2e27);
        uint256 before = irm.underwriterIndex(market);
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.underwriterIndex(market), before);
    }

    function test_termMultiplierSlope_effect() public {
        irm.setTermMultiplierSlope(0.5e27);
        assertEq(irm.termMultiplierSlope(), 0.5e27);
        assertEq(irm.termMultiplier(0), 1.5e27, "slope on top of one ray at a zero length term");
        assertEq(irm.termMultiplier(0.5e27), 1.25e27, "linear through the range");
        assertEq(irm.termMultiplier(1e27), 1e27, "one ray at the maximum term");
        assertEq(irm.termMultiplier(2e27), 1e27, "flat beyond the maximum term");
    }

    function test_termMultiplier_defaultsToOneRay() public view {
        assertEq(irm.termMultiplierSlope(), 0, "no slope configured");
        assertEq(irm.termMultiplier(0), 1e27, "a zero slope is neutral");
        assertEq(irm.termMultiplier(1e27), 1e27, "a zero slope is neutral");
    }

    function test_updateUnderwriterRate_allowsZero() public {
        vm.prank(market);
        irm.updateUnderwriterRate(0);
        assertEq(irm.underwriterRate(market), 0);
    }

    function test_updateUnderwriterRate_aboveMaximum_reverts() public {
        uint256 tooHigh = irm.maximumUnderwriterRate() + 1;
        vm.prank(market);
        vm.expectRevert(IInterestRateModel.InvalidRate.selector);
        irm.updateUnderwriterRate(tooHigh);
    }

    /// @dev The stablecoin calls in after its supplies have already moved, so the accrual has to
    /// credit the elapsed interval with the observation from the previous call rather than the one
    /// arriving now. A reading that has existed for no time must earn nothing.
    function test_averageIgnoresAReadingThatHasStoodForNoTime() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();

        skip(irm.averagingPeriod());
        irm.updateLiquidityRate();
        assertEq(irm.averageUtilization(), 0.2e27, "a full quiet period settles on what stood through it");

        // the move and the report of it land together, exactly as the stablecoin does it
        stablecoin.setSupplyUtilization(0.9e27);
        irm.updateLiquidityRate();
        assertEq(irm.averageUtilization(), 0.2e27, "and the new reading starts from zero weight");
    }

    /// @dev Anyone may call {updateLiquidityRate}, so forcing an accrual is free. It buys nothing:
    /// the fold uses the observation from before the caller's own move, and the move that follows
    /// is left with no elapsed time to be weighted on.
    function test_forcingAnAccrualDoesNotAdvanceAManipulation() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(irm.averagingPeriod());

        vm.startPrank(stranger);
        irm.updateLiquidityRate();
        stablecoin.setSupplyUtilization(0.9e27);
        irm.updateLiquidityRate();
        vm.stopPrank();

        assertEq(irm.averageUtilization(), 0.2e27, "the clock was reset before the manipulation, not after");
    }

    /// @dev A sustained shift is partly in after part of a window and asymptotically the rest of
    /// the way after that.
    ///
    /// The window is a time constant rather than a deadline: the average sheds
    /// {retentionPerSecond} of its distance per second, so one whole period carries it about 63%
    /// of the way and no finite time carries it exactly all of it. That is what makes the average
    /// independent of how often the accrual runs, and it costs the clean arithmetic the linear
    /// weight had — half a period used to land on exactly half the distance. Ordering is pinned
    /// strictly and the endpoints loosely, since the figure is the quotient of two decays.
    function test_averageConvergesWithTheTimeAReadingHolds() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(_untilSettled());
        irm.updateLiquidityRate();
        assertApproxEqRel(irm.averageUtilization(), 0.2e27, 1e12, "settled on the standing reading");

        stablecoin.setSupplyUtilization(0.4e27);
        irm.updateLiquidityRate();

        skip(irm.averagingPeriod() / 2);
        uint256 halfway = irm.averageUtilization();

        skip(_untilSettled());
        uint256 settled = irm.averageUtilization();

        assertGt(halfway, 0.2e27, "half a period moves it off the reading it had settled on");
        assertLt(halfway, 0.4e27, "without taking it all the way to the new one");
        assertApproxEqRel(settled, 0.4e27, 1e12, "which enough quiet time does");
    }

    /// @dev The mint is added to the averaged supplies rather than smoothed away, so a borrower
    /// still pays for the utilization their own draw creates.
    ///
    /// Settled first, because the mint is an absolute amount added to averaged supplies: measured
    /// against supplies still climbing towards their true level it would read as a larger share
    /// of the pool than it is, and this is about the arithmetic rather than the convergence.
    function test_averageStillCountsAMintThatHasNotHappenedYet() public {
        stablecoin.setSupplyUtilization(0.5e27);
        irm.updateLiquidityRate();
        skip(_untilSettled());
        irm.updateLiquidityRate();

        // the mock reports the pair as (0.5e27, 1e27), so a quarter-ray mint lands at 0.75/1.25
        assertApproxEqRel(
            irm.averageUtilizationAfterMint(0.25e27), 0.6e27, 1e12, "the draw moves the level it is priced at"
        );
    }

    /// @dev Compared against the figure standing immediately before the change rather than a
    /// constant, which is the actual claim: the interval that has run is settled under the window
    /// it ran under, so widening cannot reach back and reweight it.
    function test_setAveragingPeriod_movesTheWindowAndSettlesTheOldOne() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(_untilSettled());
        irm.updateLiquidityRate();

        stablecoin.setSupplyUtilization(0.4e27);
        irm.updateLiquidityRate();
        skip(30 minutes);
        uint256 earned = irm.averageUtilization();

        irm.setAveragingPeriod(2 hours);

        assertEq(irm.averagingPeriod(), 2 hours);
        assertEq(irm.averageUtilization(), earned, "time already served keeps the weight it was served under");
    }

    /// @dev Long enough that the residual is beneath the tolerances above. Twenty time constants
    /// leaves `e^-20`, around two parts in a billion.
    function _untilSettled() internal view returns (uint256 quiet) {
        quiet = 20 * irm.averagingPeriod();
    }

    // ── the average does not depend on how often it is accrued ────────────────

    /// @dev Advance a period's worth of time in `slices` equal steps, accruing at each one
    function _runAPeriodIn(uint256 slices) internal returns (uint256 average) {
        uint256 step = irm.averagingPeriod() / slices;
        for (uint256 i; i < slices; ++i) {
            skip(step);
            irm.updateLiquidityRate();
        }
        average = irm.averageUtilization();
    }

    /// @dev The property the whole averaging rests on, and the one it did not have.
    ///
    /// {updateLiquidityRate} is permissionless, and worse, the stablecoin runs the same accrual on
    /// every deposit, mint and withdrawal — so a one-wei deposit triggers it and there is no way
    /// to gate it. Under the old per-call weight of `elapsed / period`, cutting an interval up
    /// made the average converge more slowly: half the interval twice retained a quarter of the
    /// stale average where the whole interval retained none, and finer cuts converged on `1/e`,
    /// leaving 36.8% of a stale reading in place. A fixed borrower could hold the average down
    /// near an old low reading and be quoted off utilisation that had already moved, and even
    /// without an attacker the figure depended on how busy the protocol happened to be.
    ///
    /// A per-second retention raised to the elapsed seconds composes instead, so the number of
    /// slices cannot matter. Compared against a single accrual over the whole interval, so this
    /// pins the value and not merely that the slices agree with each other.
    function test_theAverageIsTheSameHoweverOftenItIsAccrued() public {
        uint256 fixture = vm.snapshotState();

        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(_untilSettled());
        irm.updateLiquidityRate();
        stablecoin.setSupplyUtilization(0.9e27);
        irm.updateLiquidityRate();
        uint256 shifted = vm.snapshotState();

        uint256 once = _runAPeriodIn(1);

        uint256[4] memory splits = [uint256(2), 10, 60, 360];
        for (uint256 i; i < splits.length; ++i) {
            vm.revertToState(shifted);
            uint256 spammed = _runAPeriodIn(splits[i]);

            // a ray of headroom on a ray-scaled figure: the rounding in `rayPow` is half-up per
            // squaring, so a longer path can retain a few ulps more. Nothing an attacker can
            // widen, and nine orders of magnitude off the 36.8% the old weight gave away
            assertApproxEqAbs(spammed, once, 1e9, "the number of accruals cannot move the average");
        }

        // and the fixture really was one where the old weight would have differed
        vm.revertToState(fixture);
        assertLt(once, 0.9e27, "the average is mid-shift, so a slower convergence would show");
        assertGt(once, 0.2e27, "and has left the reading it started from");
    }

    function test_setAveragingPeriod_outsideTheBand_reverts() public {
        uint256 tooShort = irm.MINIMUM_AVERAGING_PERIOD() - 1;
        uint256 tooLong = irm.MAXIMUM_AVERAGING_PERIOD() + 1;

        vm.expectRevert(IInterestRateModel.InvalidAveragingPeriod.selector);
        irm.setAveragingPeriod(tooShort);

        vm.expectRevert(IInterestRateModel.InvalidAveragingPeriod.selector);
        irm.setAveragingPeriod(tooLong);

        assertEq(irm.averagingPeriod(), 1 hours, "and the window it started with is untouched");
    }

    function test_setAveragingPeriod_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        irm.setAveragingPeriod(2 hours);
    }

    function test_upgrade_authorized() public {
        InterestRateModel newImpl = new InterestRateModel();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
        (, uint256 index,) = irm.liquidityData();
        assertEq(index, RAY);
    }

    function test_upgrade_unauthorized_reverts() public {
        InterestRateModel newImpl = new InterestRateModel();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
    }
}
