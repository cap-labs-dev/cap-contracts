// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { CapIntegrationFixture } from "../fixtures/CapIntegrationFixture.sol";

/// @dev Sanity-check view wiring and addressbook-derived constants on the Eigen service manager.
contract EigenServiceManagerViewTest is CapIntegrationFixture {
    EigenServiceManager eigenServiceManager;

    function setUp() public {
        _setUpCap();
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
