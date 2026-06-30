// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { CapDeployer } from "./CapDeployer.sol";

/// @notice Covers premium routing when a tranche is empty, the decreaseRewardDebt settle path,
/// and a liquidation that slashes through the junior tranche into the senior tranche.
contract RewardRoutingTest is CapDeployer {
    address internal manager = makeAddr("manager");
    address internal borrower = makeAddr("borrower");
    address internal jSup = makeAddr("jSup");
    address internal sSup = makeAddr("sSup");

    function setUp() public {
        _deployCap();
    }

    /// @dev Build a configured market and (optionally) fund each tranche.
    function _setupMarket(string memory name, uint256 juniorAmt, uint256 seniorAmt)
        internal
        returns (bytes32 id, address senior, address junior)
    {
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        (id, senior, junior) = _createMarket(name, manager, bs);

        _setMarketSlopes(id);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        lender.setMultiplier(id, 1e27);
        vm.prank(senior);
        rewarder.setJuniorSplit(id, 0.5e27);

        if (juniorAmt > 0) _fundUnderwriter(junior, manager, jSup, juniorAmt);
        if (seniorAmt > 0) _fundUnderwriter(senior, manager, sSup, seniorAmt);

        lender.setBorrowCap(id, 1_000e18);
    }

    // --- empty senior tranche: premium falls back onto the junior tranche ---

    function test_emptySenior_routesPremiumToJunior() public {
        (bytes32 id, address senior, address junior) = _setupMarket("Senior Empty", 1_000e18, 0);

        vm.prank(borrower);
        lender.borrow(id, borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        rewarder.updateRewards(id);

        // junior collects both its own split and the (empty) senior split
        assertGt(rewarder.claimableUnderwriterReward(id, junior, jSup), 0);
        // senior has no supply, so it accrues nothing
        assertEq(rewarder.claimableUnderwriterReward(id, senior, sSup), 0);
    }

    // --- empty junior tranche: premium falls back onto the senior tranche ---

    function test_emptyJunior_routesPremiumToSenior() public {
        (bytes32 id, address senior, address junior) = _setupMarket("Junior Empty", 0, 1_000e18);

        vm.prank(borrower);
        lender.borrow(id, borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        rewarder.updateRewards(id);

        assertGt(rewarder.claimableUnderwriterReward(id, senior, sSup), 0);
        assertEq(rewarder.claimableUnderwriterReward(id, junior, jSup), 0);
    }

    // --- redeem after rewards accrue exercises decreaseRewardDebt's settle path ---

    function test_redeemAfterAccrual_settlesRewardDebt() public {
        (bytes32 id, address senior,) = _setupMarket("Redeem", 600e18, 400e18);

        vm.prank(borrower);
        lender.borrow(id, borrower, 400e18);
        vm.warp(block.timestamp + 365 days);

        uint256 before = rewarder.claimableUnderwriterReward(id, senior, sSup);
        assertGt(before, 0);

        // fund the borrower to cover interest that accrued beyond the principal, then fully repay so
        // the senior tranche's shares unlock and can be redeemed
        _mintStable(borrower, lender.debt(id));
        vm.prank(borrower);
        lender.repay(id, type(uint256).max);

        Underwriter seniorVault = Underwriter(senior);
        vm.startPrank(sSup);
        uint256 reqId = seniorVault.requestRedeem(100e18, sSup, sSup);
        seniorVault.redeem(reqId, 100e18, sSup, sSup);
        vm.stopPrank();

        // pending reward survived the share burn (checkpointed into pendingReward)
        assertGt(rewarder.claimableUnderwriterReward(id, senior, sSup), 0);
    }

    // --- a borrow that scales (half-up) to zero debt shares is rejected ---

    function test_borrow_dustBelowIndex_reverts() public {
        // a deep tranche keeps credit available even after the index compounds far past 2e27
        (bytes32 id,,) = _setupMarket("Dust", 1_000_000e18, 0);

        vm.prank(borrower);
        lender.borrow(id, borrower, 1);
        // grow the index past 2e27 while debt stays negligible vs. the large credit line
        vm.warp(block.timestamp + 36500 days);

        vm.prank(borrower);
        vm.expectRevert(ILender.InvalidAmount.selector);
        lender.borrow(id, borrower, 1);
    }

    // --- liquidation slashes through the junior tranche into the senior tranche ---

    function test_liquidate_slashesThroughJuniorIntoSenior() public {
        // a near-empty junior tranche forces the slash to spill over into the senior tranche
        uint256 juniorTiny = 1e6;
        (bytes32 id,,) = _setupMarket("Spillover", juniorTiny, 1_000e18);

        vm.prank(borrower);
        lender.borrow(id, borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);
        uint256 max = lender.maxLiquidatable(id);
        assertGt(max, 0);

        // fund the liquidator so the burn can be covered
        _mintStable(borrower, max);

        vm.prank(borrower);
        (uint256 repaid,, uint256 slashed) = lender.liquidate(id, borrower, type(uint256).max);

        assertGt(repaid, 0);
        // more was slashed than the junior tranche held, so the senior tranche was tapped
        assertGt(slashed, juniorTiny);
    }
}
