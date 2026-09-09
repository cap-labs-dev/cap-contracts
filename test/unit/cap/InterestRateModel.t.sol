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
        uint256 before = irm.liquidityIndex(market);
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.liquidityIndex(market), before);
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

    /// @dev Half a period of a sustained shift is half of the distance travelled
    function test_averageConvergesWithTheTimeAReadingHolds() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(irm.averagingPeriod());
        irm.updateLiquidityRate();

        stablecoin.setSupplyUtilization(0.4e27);
        irm.updateLiquidityRate();

        skip(irm.averagingPeriod() / 2);
        assertEq(irm.averageUtilization(), 0.3e27, "halfway there after half the window");
    }

    /// @dev The mint is added to the averaged supplies rather than smoothed away, so a borrower
    /// still pays for the utilization their own draw creates
    function test_averageStillCountsAMintThatHasNotHappenedYet() public {
        stablecoin.setSupplyUtilization(0.5e27);
        irm.updateLiquidityRate();
        skip(irm.averagingPeriod());
        irm.updateLiquidityRate();

        // the mock reports the pair as (0.5e27, 1e27), so a quarter-ray mint lands at 0.75/1.25
        assertEq(irm.averageUtilizationAfterMint(0.25e27), 0.6e27, "the draw moves the level it is priced at");
    }

    function test_setAveragingPeriod_movesTheWindowAndSettlesTheOldOne() public {
        stablecoin.setSupplyUtilization(0.2e27);
        irm.updateLiquidityRate();
        skip(irm.averagingPeriod());
        irm.updateLiquidityRate();

        stablecoin.setSupplyUtilization(0.4e27);
        irm.updateLiquidityRate();
        skip(30 minutes);

        // half of the old hour has run, so half the distance is already earned and widening the
        // window must not claw that back
        irm.setAveragingPeriod(2 hours);
        assertEq(irm.averagingPeriod(), 2 hours);
        assertEq(irm.averageUtilization(), 0.3e27, "time already served keeps the weight it was served under");
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
