// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title VestingScheduleTest
/// @notice Premium accrual divides by the vesting period and clamps at the vesting end, so both
/// are reachable from governance setters and both used to be able to brick the contracts.
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
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(senior, supplier, 1_000e18);
    }

    function _accrueSomePremium() internal {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
    }

    function test_tranche_zeroVestingPeriodRejected() public {
        _accrueSomePremium();
        vm.expectRevert(ITranche.InvalidVestingPeriod.selector);
        Tranche(senior).setVestingPeriod(0);
    }

    /// Changing the period must not brick share movement, claims or deposits.
    function test_tranche_vestingPeriodChangeKeepsTrancheLive() public {
        _accrueSomePremium();
        assertGt(Tranche(senior).vested(), 0, "premium should be vesting");

        vm.warp(block.timestamp + 1 hours);
        Tranche(senior).setVestingPeriod(1 days);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(supplier);
        Tranche(senior).transfer(makeAddr("bob"), 1e18);

        vm.prank(supplier);
        Tranche(senior).claim(supplier);

        _fundTranche(senior, makeAddr("second"), 10e18);
    }

    /// Shortening the period must not release premium that has not vested under the new schedule.
    function test_tranche_shorteningPeriodDoesNotOverRelease() public {
        _accrueSomePremium();
        vm.warp(block.timestamp + 1 hours);

        uint256 claimableBefore = Tranche(senior).claimable(supplier);
        Tranche(senior).setVestingPeriod(1 days);

        assertApproxEqAbs(
            Tranche(senior).claimable(supplier), claimableBefore, 1e12, "reschedule must not release a jump"
        );
    }

    function test_underwriter_zeroVestingPeriodRejected() public {
        Underwriter uw = _deployUnderwriter();
        vm.expectRevert(IUnderwriter.InvalidVestingPeriod.selector);
        uw.setVestingPeriod(0);
    }

    /// Shrinking the period used to move vestingEnd behind lastPremiumUpdate and revert. Accrual
    /// still clamps; the leftover locked premium is recaptured into the new window.
    function test_underwriter_shrinkingPeriodKeepsUnderwriterLive() public {
        Tranche(senior).setWhitelist(address(this), true);
        Underwriter uw = _deployUnderwriter();
        Tranche(senior).setWhitelist(address(uw), true);
        _fundUnderwriter(address(uw), supplier, 1_000e18);
        uw.addTranche(senior);
        uw.allocate(senior, 500e18);

        _accrueSomePremium();
        uw.report(senior);

        vm.warp(block.timestamp + 5 hours);
        uw.claim();
        assertGt(uw.lastPremiumUpdate(), 0, "accrual happened");

        uw.setVestingPeriod(1 hours);
        assertEq(uw.vestingEnd(), block.timestamp + 1 hours, "clock restarts over the new period");
        assertEq(uw.lastPremiumUpdate(), block.timestamp, "accrual cursor reset to now");

        uw.claimable(supplier);
        uw.claim();
        uw.report(senior);

        vm.prank(supplier);
        uw.transfer(makeAddr("bob"), 1e18);

        vm.prank(supplier);
        uw.requestRedeem(1e18, supplier, supplier);
    }

    /// Shortening the period must not strand the unvested remainder on the contract.
    function test_underwriter_shorteningPeriodDoesNotStrandPremium() public {
        Tranche(senior).setWhitelist(address(this), true);
        Underwriter uw = _deployUnderwriter();
        Tranche(senior).setWhitelist(address(uw), true);
        _fundUnderwriter(address(uw), supplier, 1_000e18);
        uw.addTranche(senior);
        uw.allocate(senior, 500e18);

        _accrueSomePremium();
        // let the tranche vest so report actually pulls cUSD
        vm.warp(block.timestamp + 6 hours);
        uw.report(senior);
        assertGt(uw.vestedPremium(), 0, "underwriter has premium to vest");

        vm.warp(block.timestamp + 5 hours);
        uint256 leftover = uw.vestedReward();
        assertGt(leftover, 0, "some premium still locked");
        uint256 claimableBefore = uw.claimable(supplier);

        uw.setVestingPeriod(1 hours);
        assertEq(uw.vestedPremium(), leftover, "locked remainder recaptured");

        vm.warp(block.timestamp + 1 hours);
        assertApproxEqAbs(
            uw.claimable(supplier) - claimableBefore, leftover, 1 hours, "remainder unlocks over the new period"
        );
    }
}
