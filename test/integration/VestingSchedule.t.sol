// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title VestingScheduleTest
/// @notice The time constant is twelve hours, so a day releases most of a pot without a setter that
/// can move the schedule out from under accrual.
contract VestingScheduleTest is CapDeployer {
    FloatingMarket internal market;
    address internal senior;
    address internal junior;
    address internal supplier = makeAddr("supplier");

    function setUp() public {
        _deployCap();
        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("M");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        _setMaxCapital(market, 100_000e18);
        _fundTranche(senior, supplier, 1_000e18);
    }

    function _accrueSomePremium() internal {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
    }

    function test_vestingPeriodIsSixHours() public view {
        assertEq(Tranche(senior).vestingPeriod(), 12 hours);
        assertEq(Tranche(senior).VESTING_PERIOD(), 12 hours);
    }

    /// After two time constants a day has passed and about `1 - 1/e^2` has been released.
    function test_aDayReleasesMostOfThePot() public {
        _accrueSomePremium();
        uint256 pot = Tranche(senior).remaining() + Tranche(senior).vested();
        assertGt(pot, 0, "premium is vesting");

        vm.warp(block.timestamp + 24 hours);
        assertApproxEqRel(Tranche(senior).vested(), pot * 8647 / 10_000, 0.01e18, "1 - 1/e^2");
        assertLt(Tranche(senior).remaining(), pot / 5, "less than twenty percent still locked");
    }

    /// The fixed schedule must not brick share movement, claims or deposits.
    function test_trancheStaysLiveWhilePremiumVests() public {
        _accrueSomePremium();
        assertGt(Tranche(senior).remaining(), 0, "premium should be vesting");

        vm.warp(block.timestamp + 1 hours);

        vm.prank(supplier);
        assertTrue(Tranche(senior).transfer(makeAddr("bob"), 1e18));

        vm.prank(supplier);
        Tranche(senior).claim(supplier);

        _fundTranche(senior, makeAddr("second"), 10e18);
    }

    function test_underwriterUsesTheSameConstant() public {
        Underwriter uw = _deployUnderwriter();
        assertEq(uw.vestingPeriod(), 12 hours);
        assertEq(uw.VESTING_PERIOD(), 12 hours);
    }
}
