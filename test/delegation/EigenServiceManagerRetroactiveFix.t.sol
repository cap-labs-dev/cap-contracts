// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

interface ILenderRepay {
    function repay(address _asset, uint256 _amount, address _agent) external returns (uint256 repaid);
    function debt(address _agent, address _asset) external view returns (uint256 totalDebt);
    function accruedRestakerInterest(address _agent, address _asset) external view returns (uint256 accruedInterest);
}

interface IEigenServiceManagerViews {
    function pendingRewards(address _operator, address _token) external view returns (uint256);
}

interface IRewardsCoordinatorViews {
    function MAX_RETROACTIVE_LENGTH() external view returns (uint32);
}

/// @dev Mainnet fork regression test for the repay DoS caused by stale Eigen rewards submissions.
///
/// Live state on ETH mainnet (Aug 2026): agent 0x89Ff...67D6 has had no USDC rewards distribution since its
/// operator creation epoch (Jan 2026). EigenServiceManager._createRewardsSubmission derived
/// startTimestamp from that epoch, which is older than the RewardsCoordinator's MAX_RETROACTIVE_LENGTH
/// (168 days), so createOperatorDirectedOperatorSetRewardsSubmission reverted with
/// StartTimestampTooFarInPast() and blocked Lender.repay (and liquidate) entirely.
///
/// The fix clamps startTimestamp to the oldest interval-aligned timestamp inside the retroactive window.
///
/// Run with: forge test --match-contract EigenServiceManagerRetroactiveFixTest -vvv
/// Requires ETH_RPC_URL to be set; the test is skipped otherwise.
contract EigenServiceManagerRetroactiveFixTest is Test {
    /// @dev EigenLayer RewardsCoordinator error that blocked repayments
    error StartTimestampTooFarInPast();

    address constant LENDER = 0x15622c3dbbc5614E6DFa9446603c1779647f01FC;
    address constant ESM = 0xE65c3eccd18879E103dBC96D854e376Ced4cC7dd;
    address constant AGENT = 0x89Ffc736225bbfaA18aC20a846203CDbe7cC67D6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant REWARDS_COORDINATOR = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;

    /// @dev ERC1967 implementation slot
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 constant REPAY_AMOUNT = 120_000e6;

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    /// @dev Reproduces the live failure: repay reverts with the RewardsCoordinator's
    /// StartTimestampTooFarInPast() while the unfixed implementation is active.
    function test_repay_blockedByStaleRewardsSubmission_beforeFix() public {
        if (!forked) return;
        _fundAndApprove();

        vm.prank(AGENT);
        vm.expectRevert(StartTimestampTooFarInPast.selector);
        ILenderRepay(LENDER).repay(USDC, REPAY_AMOUNT, AGENT);
    }

    /// @dev Upgrades the ESM proxy to the fixed implementation and shows the exact same repay succeeds,
    /// with the restaker interest actually submitted to the RewardsCoordinator.
    function test_repay_succeedsAfterFix() public {
        if (!forked) return;
        _fundAndApprove();

        // sanity: still broken pre-upgrade
        vm.prank(AGENT);
        vm.expectRevert(StartTimestampTooFarInPast.selector);
        ILenderRepay(LENDER).repay(USDC, REPAY_AMOUNT, AGENT);

        _upgradeToFixedImplementation();

        uint256 debtBefore = ILenderRepay(LENDER).debt(AGENT, USDC);
        uint256 accruedBefore = ILenderRepay(LENDER).accruedRestakerInterest(AGENT, USDC);
        uint256 agentBalBefore = IERC20(USDC).balanceOf(AGENT);
        uint256 coordinatorBalBefore = IERC20(USDC).balanceOf(REWARDS_COORDINATOR);
        assertGt(accruedBefore, 0, "test premise: restaker interest must be pending realization");

        vm.prank(AGENT);
        uint256 repaid = ILenderRepay(LENDER).repay(USDC, REPAY_AMOUNT, AGENT);

        assertEq(repaid, REPAY_AMOUNT, "full amount repaid");
        assertEq(IERC20(USDC).balanceOf(AGENT), agentBalBefore - REPAY_AMOUNT, "agent paid the USDC");
        assertApproxEqAbs(
            ILenderRepay(LENDER).debt(AGENT, USDC), debtBefore - REPAY_AMOUNT, 1e4, "debt reduced by repay amount"
        );

        // Restaker interest was realized and actually submitted to the RewardsCoordinator, meaning the
        // clamped submission passed the retroactive window validation instead of parking as pending.
        assertGe(
            IERC20(USDC).balanceOf(REWARDS_COORDINATOR),
            coordinatorBalBefore + accruedBefore,
            "restaker interest forwarded to RewardsCoordinator"
        );
        assertEq(IEigenServiceManagerViews(ESM).pendingRewards(AGENT, USDC), 0, "no rewards left parked as pending");
        assertEq(ILenderRepay(LENDER).accruedRestakerInterest(AGENT, USDC), 0, "accrued interest realized");
    }

    /// @dev After the fixed distribution, subsequent repays keep working: newly accrued restaker interest
    /// inside the distribution interval takes the pending-rewards branch (no submission) and does not revert.
    /// A longer warp is not possible on the fork because Chainlink feeds go stale (PriceError).
    function test_subsequentRepay_unaffectedByClamp() public {
        if (!forked) return;
        _fundAndApprove();
        _upgradeToFixedImplementation();

        vm.prank(AGENT);
        ILenderRepay(LENDER).repay(USDC, 60_000e6, AGENT);
        assertEq(IEigenServiceManagerViews(ESM).pendingRewards(AGENT, USDC), 0, "first distribution submitted");

        // accrue a little more restaker interest and repay again shortly after
        vm.warp(block.timestamp + 30 minutes);
        uint256 accrued = ILenderRepay(LENDER).accruedRestakerInterest(AGENT, USDC);
        assertGt(accrued, 0, "test premise: interest accrued since first repay");

        vm.prank(AGENT);
        uint256 repaid = ILenderRepay(LENDER).repay(USDC, 10_000e6, AGENT);
        assertEq(repaid, 10_000e6, "subsequent repay succeeds");
        assertGe(
            IEigenServiceManagerViews(ESM).pendingRewards(AGENT, USDC),
            accrued,
            "interest inside the distribution interval parks as pending instead of reverting"
        );
    }

    function _fundAndApprove() internal {
        deal(USDC, AGENT, 200_000e6);
        vm.prank(AGENT);
        IERC20(USDC).approve(LENDER, type(uint256).max);
    }

    function _upgradeToFixedImplementation() internal {
        assertTrue(uint256(vm.load(ESM, IMPL_SLOT)) != 0, "ESM is not an ERC1967 proxy");
        address fixedImpl = address(new EigenServiceManager());
        vm.store(ESM, IMPL_SLOT, bytes32(uint256(uint160(fixedImpl))));
    }
}
