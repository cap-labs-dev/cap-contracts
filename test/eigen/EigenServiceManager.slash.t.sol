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
        assertApproxEqAbs(collateral.balanceOf(recipient), 1e18, 1);

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
        assertApproxEqAbs(collateral.balanceOf(recipient), 10, 1);

        // coverage should have been reduced by 10%
        //uint256 approximatedPostSlashCoverage = coverage * 0.9e8 / 1e8;
        //uint256 coverageAfterSlash = eigenServiceManager.coverage(agent);
        //uint256 slashableCollateralAfterSlash = eigenServiceManager.slashableCollateral(agent, 0);

        //assertApproxEqAbs(eigenServiceManager.coverage(agent), approximatedPostSlashCoverage, 1);
        //assertEq(slashableCollateralAfterSlash, coverageAfterSlash);

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
}
