// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IStrategy } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract EigenServiceManagerViewTest is TestDeployer {
    EigenServiceManager eigenServiceManager;

    function setUp() public {
        _deployCapTestEnvironment();
        eigenServiceManager = EigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
    }

    function test_eigen_service_manager_view_functions() public view {
        address agent = env.testUsers.agents[1];

        uint32 operatorSetId = eigenServiceManager.operatorSetId(agent);
        assertEq(operatorSetId, 1);

        address strategy = eigenServiceManager.operatorToStrategy(agent);
        assertEq(strategy, eigenAb.eigenAddresses.strategy);

        EigenServiceManager.EigenAddresses memory _eigenAddresses = eigenServiceManager.eigenAddresses();
        assertEq(_eigenAddresses.delegationManager, eigenAb.eigenAddresses.delegationManager);
        assertEq(_eigenAddresses.strategyManager, eigenAb.eigenAddresses.strategyManager);
        assertEq(_eigenAddresses.allocationManager, eigenAb.eigenAddresses.allocationManager);
        assertEq(_eigenAddresses.rewardsCoordinator, eigenAb.eigenAddresses.rewardsCoordinator);

        uint256 epochsBetweenDistributions = eigenServiceManager.epochsBetweenDistributions();
        assertEq(epochsBetweenDistributions, 7);

        uint256 pendingRewards = eigenServiceManager.pendingRewards(eigenAb.eigenAddresses.strategy, address(usdc));
        assertEq(pendingRewards, 0);
    }
}
