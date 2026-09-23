// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IPremiumVesting } from "../../contracts/interfaces/IPremiumVesting.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { CapRoles } from "../shared/CapRoles.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title VestingScheduleTest
/// @notice Floating tranches and underwriters start at twelve hours, so a day releases most of a pot.
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

    function test_vestingPeriodStartsAtTwelveHours() public view {
        assertEq(Tranche(senior).vestingPeriod(), 12 hours);
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

    function test_underwriterStartsWithTheSamePeriod() public {
        Underwriter uw = _deployUnderwriter();
        assertEq(uw.vestingPeriod(), 12 hours);
    }

    function test_fixedTranchesStartAtHalfMaximumTermAndKeepTheirOwnPeriod() public {
        uint256 maximum = 31 days + 1;
        (address m, address[] memory ts) = registry.createFixedMarket(
            _uniformAssets(2),
            capConfig.defaultTrancheWeights,
            "Fixed vesting",
            _operatorRoleOf(defaultMarketOwner),
            maximum,
            1 days,
            1 days
        );
        assertEq(Tranche(ts[0]).vestingPeriod(), maximum / 2);
        assertEq(Tranche(ts[1]).vestingPeriod(), maximum / 2);
        FixedMarket(m).setTermLimits(60 days, 1 days);
        assertEq(Tranche(ts[0]).vestingPeriod(), maximum / 2, "term changes do not silently reprice existing vesting");
        assertEq(stablecoin.vestingPeriod(), 12 hours);
        assertEq(Tranche(senior).vestingPeriod(), 12 hours);
    }

    function test_newTrancheUsesExplicitPeriodAndRejectsZero() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = RAY;
        vm.expectRevert(IPremiumVesting.InvalidVestingPeriod.selector);
        registry.createTranche(address(market), address(collateral), weights, 0);
        address t = registry.createTranche(address(market), address(collateral), weights, 7 days);
        assertEq(Tranche(t).vestingPeriod(), 7 days);
    }

    function test_governorControlsStablecoinAndTranchePeriodsWhileCuratorControlsPool() public {
        Underwriter uw = _deployUnderwriter();
        address governor = makeAddr("vesting governor");
        address curator = makeAddr("vesting curator");
        address outsider = makeAddr("vesting outsider");
        accessManager.grantRole(CapRoles.GOVERNOR, governor, 0);
        accessManager.grantRole(_operatorRoleOf(address(this)), curator, 0);
        address[3] memory targets = [address(stablecoin), senior, address(uw)];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(outsider);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider));
            IPremiumVesting(targets[i]).setVestingPeriod(3 days);
        }
        vm.startPrank(governor);
        stablecoin.setVestingPeriod(2 days);
        Tranche(senior).setVestingPeriod(3 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor));
        uw.setVestingPeriod(4 days);
        vm.stopPrank();
        vm.startPrank(curator);
        uw.setVestingPeriod(4 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator));
        stablecoin.setVestingPeriod(5 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator));
        Tranche(senior).setVestingPeriod(5 days);
        vm.stopPrank();
        assertEq(stablecoin.vestingPeriod(), 2 days);
        assertEq(Tranche(senior).vestingPeriod(), 3 days);
        assertEq(uw.vestingPeriod(), 4 days);
    }

    function test_harvestedPremiumRevestsForCurrentPoolHolders() public {
        Underwriter uw = _deployUnderwriter();
        uw.setVestingPeriod(7 days);
        uw.addTranche(senior);
        uw.setDefaultTranche(senior);
        _admitDepositor(senior, address(uw));
        _fundUnderwriter(address(uw), supplier, 1_000e18);
        _accrueSomePremium();
        vm.warp(block.timestamp + 20 * Tranche(senior).vestingPeriod());
        uw.report(senior);
        uint256 harvested = stablecoin.balanceOf(address(uw));
        assertGt(harvested, 0);
        assertEq(uw.claimable(supplier), 0, "harvest starts a separate pool vesting schedule");
        address late = makeAddr("late pool depositor");
        _fundUnderwriter(address(uw), late, 1_000e18);
        assertEq(uw.claimable(late), 0, "entry does not immediately own vested premium");
        vm.warp(block.timestamp + 7 days);
        uint256 earned = uw.claimable(late);
        assertGt(earned, harvested * 3 / 10);
        assertLt(earned, harvested / 3, "half of approximately 63% after one period");
        vm.prank(late);
        assertEq(uw.claim(late), earned);
    }
}
