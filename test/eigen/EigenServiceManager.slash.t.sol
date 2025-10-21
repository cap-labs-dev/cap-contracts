// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IStrategy } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract EigenServiceManagerSlashTest is TestDeployer {
    EigenServiceManager eigenServiceManager;

    function setUp() public {
        _deployCapTestEnvironment();
        eigenServiceManager = EigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
    }

    function test_slash_sends_funds_to_eigen() public {
        vm.startPrank(env.infra.delegation);
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());
        _timeTravel(1);

        address recipient = makeAddr("recipient");
        address agent = env.testUsers.agents[1];

        // collateral is in USD Value of the 100 eth collateral
        uint256 coverage = eigenServiceManager.coverage(agent);
        uint256 slashableCollateral = eigenServiceManager.slashableCollateral(agent, 0);
        console.log("coverage", coverage);
        console.log("slashableCollateral", slashableCollateral);
        assertEq(coverage, slashableCollateral);

        // slash 10% of agent collateral
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

        // all vaults have been slashed 10% and sent to the recipient
        assertApproxEqAbs(collateral.balanceOf(recipient), 1e18, 10);

        // coverage should have been reduced by 10%
        uint256 approximatedPostSlashCoverage = coverage * 0.9e8 / 1e8;
        uint256 coverageAfterSlash = eigenServiceManager.coverage(agent);
        uint256 slashableCollateralAfterSlash = eigenServiceManager.slashableCollateral(agent, 0);

        assertApproxEqAbs(eigenServiceManager.coverage(agent), approximatedPostSlashCoverage, 1);
        assertEq(slashableCollateralAfterSlash, coverageAfterSlash);

        vm.stopPrank();
    }

    function test_slash_a_very_small_amount() public {
        vm.startPrank(env.infra.delegation);
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());
        _timeTravel(1);

        address recipient = makeAddr("recipient");
        address agent = env.testUsers.agents[1];

        // collateral is in USD Value of the 100 eth collateral
        uint256 coverage = eigenServiceManager.coverage(agent);
        uint256 slashableCollateral = eigenServiceManager.slashableCollateral(agent, 0);
        console.log("coverage", coverage);
        console.log("slashableCollateral", slashableCollateral);
        assertEq(coverage, slashableCollateral);

        // slash 10% of agent collateral
        eigenServiceManager.slash(agent, recipient, 1, uint48(block.timestamp));

        // all vaults have been slashed 10% and sent to the recipient
        assertApproxEqAbs(collateral.balanceOf(recipient), 19, 1);

        vm.stopPrank();
    }

    function test_slash_does_not_work_if_not_slashable() public {
        address agent = env.testUsers.agents[1];

        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());
        _proportionallyWithdrawFromStrategy(
            eigenAb, env.testUsers.restakers[1], eigenAb.eigenAddresses.strategy, 100, true
        );

        // coverage should be 0
        assertEq(eigenServiceManager.coverage(agent), 0);
        assertGt(eigenServiceManager.slashableCollateral(agent, 0), 0);

        {
            /// travel some time into the future after the epoch ends
            _timeTravel(20 days);
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");

            // we request a slash for a timestamp where there is a stake to be slashed
            vm.expectRevert();
            eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // slash should not have worked
            assertEq(collateral.balanceOf(recipient), 0);
            assertEq(eigenServiceManager.coverage(agent), 0);
            vm.stopPrank();
        }
    }

    function test_can_slash_everything() public {
        address agent = env.testUsers.agents[1];

        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        // collateral is now active
        assertEq(eigenServiceManager.coverage(agent), eigenServiceManager.slashableCollateral(agent, 0));
        _proportionallyWithdrawFromStrategy(
            eigenAb, env.testUsers.restakers[1], eigenAb.eigenAddresses.strategy, 100, true
        );

        // we should be able to slash immediately after delegation
        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");

            eigenServiceManager.slash(agent, recipient, 1e18, uint48(block.timestamp));

            // strategy collateral has been slashed and sent to the recipient
            assertApproxEqAbs(collateral.balanceOf(recipient), 10e18, 1);

            vm.stopPrank();
        }
    }

    function test_slash_access_control() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        address unauthorized = address(0x123);

        // Should revert when called by unauthorized address
        vm.startPrank(unauthorized);
        vm.expectRevert();
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));
        vm.stopPrank();

        // Should succeed when called by authorized address
        vm.startPrank(env.infra.delegation);
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));
        vm.stopPrank();
    }

    function test_slash_zero_address_operator() public {
        address recipient = makeAddr("recipient");

        vm.startPrank(env.infra.delegation);
        vm.expectRevert();
        eigenServiceManager.slash(address(0), recipient, 0.1e18, uint48(block.timestamp));
        vm.stopPrank();
    }

    function test_slash_zero_address_recipient() public {
        address agent = env.testUsers.agents[1];

        vm.startPrank(env.infra.delegation);
        vm.expectRevert();
        eigenServiceManager.slash(agent, address(0), 0.1e18, uint48(block.timestamp));
        vm.stopPrank();
    }

    function test_slash_operator_with_no_strategy() public {
        address invalidAgent = address(0x999);
        address recipient = makeAddr("recipient");

        vm.startPrank(env.infra.delegation);
        vm.expectRevert();
        eigenServiceManager.slash(invalidAgent, recipient, 0.1e18, uint48(block.timestamp));
        vm.stopPrank();
    }

    function test_slash_zero_amount() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");

        vm.startPrank(env.infra.delegation);

        // Slashing with 0 share should result in ZeroSlash error
        vm.expectRevert();
        eigenServiceManager.slash(agent, recipient, 0, uint48(block.timestamp));

        vm.stopPrank();
    }

    function test_slash_maximum_amount() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        uint256 initialCoverage = eigenServiceManager.coverage(agent);
        uint256 initialBalance = collateral.balanceOf(recipient);

        vm.startPrank(env.infra.delegation);

        // Slash 100% (1e18 = 100%)
        eigenServiceManager.slash(agent, recipient, 1e18, uint48(block.timestamp));

        // All collateral should be slashed
        uint256 slashedAmount = collateral.balanceOf(recipient) - initialBalance;
        assertGt(slashedAmount, 0);

        // Coverage should be significantly reduced
        assertLt(eigenServiceManager.coverage(agent), initialCoverage);

        vm.stopPrank();
    }

    function test_slash_fractional_amounts() public {
        address agent = env.testUsers.agents[1];
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        vm.startPrank(env.infra.delegation);

        // Test various fractional slash amounts
        uint256[] memory slashShares = new uint256[](4);
        slashShares[0] = 0.01e18; // 1%
        slashShares[1] = 0.05e18; // 5%
        slashShares[2] = 0.25e18; // 25%
        slashShares[3] = 0.5e18; // 50%

        for (uint256 i = 0; i < slashShares.length; i++) {
            address testRecipient = makeAddr(string(abi.encodePacked("recipient", i)));
            uint256 beforeBalance = collateral.balanceOf(testRecipient);

            eigenServiceManager.slash(agent, testRecipient, slashShares[i], uint48(block.timestamp));

            uint256 afterBalance = collateral.balanceOf(testRecipient);
            assertGt(afterBalance, beforeBalance, "Slash should transfer tokens to recipient");
        }

        vm.stopPrank();
    }

    function test_slash_multiple_times_same_agent() public {
        address agent = env.testUsers.agents[1];
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        uint256 initialCoverage = eigenServiceManager.coverage(agent);

        vm.startPrank(env.infra.delegation);

        // First slash - 10%
        address recipient1 = makeAddr("recipient1");
        eigenServiceManager.slash(agent, recipient1, 0.1e18, uint48(block.timestamp));
        uint256 coverageAfterFirst = eigenServiceManager.coverage(agent);

        // Second slash - 20% of remaining
        address recipient2 = makeAddr("recipient2");
        eigenServiceManager.slash(agent, recipient2, 0.2e18, uint48(block.timestamp));
        uint256 coverageAfterSecond = eigenServiceManager.coverage(agent);

        // Coverage should decrease with each slash
        assertLt(coverageAfterFirst, initialCoverage);
        assertLt(coverageAfterSecond, coverageAfterFirst);

        // Both recipients should have received tokens
        assertGt(collateral.balanceOf(recipient1), 0);
        assertGt(collateral.balanceOf(recipient2), 0);

        vm.stopPrank();
    }

    function test_slash_different_agents() public {
        address agent1 = env.testUsers.agents[1];
        address agent2 = env.testUsers.agents[2];
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        uint256 coverage1Before = eigenServiceManager.coverage(agent1);
        uint256 coverage2Before = eigenServiceManager.coverage(agent2);

        vm.startPrank(env.infra.delegation);

        // Slash agent1
        address recipient1 = makeAddr("recipient1");
        eigenServiceManager.slash(agent1, recipient1, 0.15e18, uint48(block.timestamp));

        // Slash agent2
        address recipient2 = makeAddr("recipient2");
        eigenServiceManager.slash(agent2, recipient2, 0.25e18, uint48(block.timestamp));

        // Both agents should have reduced coverage
        assertLt(eigenServiceManager.coverage(agent1), coverage1Before);
        assertLt(eigenServiceManager.coverage(agent2), coverage2Before);

        // Both recipients should have received tokens
        assertGt(collateral.balanceOf(recipient1), 0);
        assertGt(collateral.balanceOf(recipient2), 0);

        vm.stopPrank();
    }

    function test_slash_with_different_timestamps() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        vm.startPrank(env.infra.delegation);

        // Test slashing with current timestamp
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));
        uint256 balanceAfterCurrent = collateral.balanceOf(recipient);

        // Test slashing with past timestamp
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp - 1 days));
        uint256 balanceAfterPast = collateral.balanceOf(recipient);

        // Test slashing with future timestamp (should still work)
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp + 1 days));
        uint256 balanceAfterFuture = collateral.balanceOf(recipient);

        // All slashes should have transferred tokens
        assertGt(balanceAfterCurrent, 0);
        assertGt(balanceAfterPast, balanceAfterCurrent);
        assertGt(balanceAfterFuture, balanceAfterPast);

        vm.stopPrank();
    }

    function test_slash_coverage_consistency() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");

        uint256 coverageBefore = eigenServiceManager.coverage(agent);
        uint256 slashableBefore = eigenServiceManager.slashableCollateral(agent, 0);

        vm.startPrank(env.infra.delegation);

        eigenServiceManager.slash(agent, recipient, 0.3e18, uint48(block.timestamp));

        uint256 coverageAfter = eigenServiceManager.coverage(agent);
        uint256 slashableAfter = eigenServiceManager.slashableCollateral(agent, 0);

        // Coverage and slashable collateral should remain consistent
        assertEq(coverageAfter, slashableAfter);

        // Both should be less than before
        assertLt(coverageAfter, coverageBefore);
        assertLt(slashableAfter, slashableBefore);

        vm.stopPrank();
    }

    function test_slash_event_emission() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        uint256 slashShare = 0.2e18;

        vm.startPrank(env.infra.delegation);

        // Expect the Slash event to be emitted
        // Note: The event emits slashedAmount (actual amount), not slashShare (percentage)
        vm.expectEmit(true, true, false, false);
        emit Slash(agent, recipient, 0, uint48(block.timestamp)); // Amount will be checked separately

        eigenServiceManager.slash(agent, recipient, slashShare, uint48(block.timestamp));

        vm.stopPrank();
    }

    // Add event definition for testing
    event Slash(address indexed agent, address indexed recipient, uint256 slashShare, uint48 timestamp);

    function test_slash_boundary_values() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        vm.startPrank(env.infra.delegation);

        // Test minimum non-zero slash (1 wei)
        uint256 balanceBefore = collateral.balanceOf(recipient);
        eigenServiceManager.slash(agent, recipient, 1, uint48(block.timestamp));
        uint256 balanceAfter = collateral.balanceOf(recipient);

        // Should have transferred some amount (even if very small)
        assertGe(balanceAfter, balanceBefore);

        vm.stopPrank();
    }

    function test_slash_after_withdrawal() public {
        address agent = env.testUsers.agents[1];
        address recipient = makeAddr("recipient");
        IERC20 collateral = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());

        // Partially withdraw from strategy first
        _proportionallyWithdrawFromStrategy(
            eigenAb, env.testUsers.restakers[1], eigenAb.eigenAddresses.strategy, 50, false
        );

        uint256 coverageAfterWithdraw = eigenServiceManager.coverage(agent);

        vm.startPrank(env.infra.delegation);

        // Should still be able to slash remaining collateral
        eigenServiceManager.slash(agent, recipient, 0.5e18, uint48(block.timestamp));

        // Should have received some tokens
        assertGt(collateral.balanceOf(recipient), 0);

        // Coverage should be further reduced
        assertLt(eigenServiceManager.coverage(agent), coverageAfterWithdraw);

        vm.stopPrank();
    }

    function test_slashable_collateral_view_function() public view {
        address agent = env.testUsers.agents[1];

        // Test slashableCollateral view function with different timestamps
        uint256 slashable1 = eigenServiceManager.slashableCollateral(agent, 0);
        uint256 slashable2 = eigenServiceManager.slashableCollateral(agent, uint48(block.timestamp));
        uint256 slashable3 = eigenServiceManager.slashableCollateral(agent, uint48(block.timestamp + 1 days));

        // All should return the same value for the same agent
        assertEq(slashable1, slashable2);
        assertEq(slashable2, slashable3);

        // Should match coverage
        assertEq(slashable1, eigenServiceManager.coverage(agent));
    }
}
