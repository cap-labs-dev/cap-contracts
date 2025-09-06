// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IStrategy } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract EigenServiceManagerRewardsTest is TestDeployer {
    EigenServiceManager eigenServiceManager;

    function setUp() public {
        _deployCapTestEnvironment();
        eigenServiceManager = EigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
    }

    function test_distribute_rewards() public {
        address agent = env.testUsers.agents[1];

        deal(address(usdc), address(eigenServiceManager), 100e6);

        vm.startPrank(env.infra.delegation);
        eigenServiceManager.distributeRewards(agent, address(usdc));

        deal(address(usdc), address(eigenServiceManager), 100e6);
        eigenServiceManager.distributeRewards(agent, address(usdc));
        assertEq(eigenServiceManager.pendingRewards(agent, address(usdc)), 100e6);
        vm.stopPrank();
    }
}
