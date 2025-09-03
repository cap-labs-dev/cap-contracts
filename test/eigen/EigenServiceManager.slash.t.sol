// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IStrategy } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract EigenServiceManagerTest is TestDeployer {
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

        // collateral in USDT (8 decimals)
        uint256 coverage = eigenServiceManager.coverage(agent);
        console.log("coverage", coverage);
        //assertEq(coverage, 780000e8);

        // slash 10% of agent collateral
        eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

        // all vaults have been slashed 10% and sent to the recipient
        assertApproxEqAbs(collateral.balanceOf(recipient), 1e18, 1);

        // coverage should have been reduced by 10%
        uint256 approximatedPostSlashCoverage = coverage * 0.9e8 / 1e8;

        assertApproxEqAbs(eigenServiceManager.coverage(agent), approximatedPostSlashCoverage, 1);

        vm.stopPrank();
    }

    /*
    function test_slash_does_not_work_if_not_slashable() public {
        address agent = _getRandomAgent();

        _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 100, true);

        _timeTravel(symbioticWethVault.vaultEpochDuration * 2 + 1);

        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");
            assertEq(eigenServiceManager.coverage(agent), 0);

            // we request a slash for a timestamp where there is a stake to be slashed
            vm.expectRevert();
            eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // slash should not have worked
            assertEq(IERC20(weth).balanceOf(recipient), 0);
            assertEq(eigenServiceManager.coverage(agent), 0);
            vm.stopPrank();
        }
    }

    function test_can_slash_immediately_after_delegation() public {
        address agent = _getRandomAgent();

        // collateral is now active
        _timeTravel(3);
        assertEq(eigenServiceManager.coverage(agent), 780000e8);

        // we should be able to slash immediately after delegation
        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");

            eigenServiceManager.slash(agent, recipient, 0.1e18, uint48(block.timestamp) - 1);

            // all vaults have been slashed 10% and sent to the recipient
            assertApproxEqAbs(IERC20(weth).balanceOf(recipient), 30e18, 1);

            vm.stopPrank();
        }
    }*/

    // ensure we can't slash if the vault epoch has ended
    // are funds active immediately after delegation?
    // can someone undelegate right before the epoch ends so that we don't have many blocks to react?
}
