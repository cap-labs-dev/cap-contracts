// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IRewardsCoordinator } from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";

interface IEigenServiceManager {
    /// @dev EigenServiceManager storage
    /// @param accessControl Access control address
    struct EigenServiceManagerStorage {
        address accessControl;
        address allocationManager;
        address delegationManager;
        address rewardsCoordinator;
        address registryCoordinator;
        address stakeRegistry;
        mapping(address => address) agentToStrategy;
    }

    /// @notice Initialize the EigenServiceManager
    /// @param _accessControl Access control contract
    /// @param _allocationManager Allocation Manager contract
    /// @param _delegationManager Delegation Manager contract
    /// @param _rewardsCoordinator Rewards Coordinator contract
    /// @param _registryCoordinator Registry Coordinator contract
    /// @param _stakeRegistry Stake Registry contract
    function initialize(
        address _accessControl,
        address _allocationManager,
        address _delegationManager,
        address _rewardsCoordinator,
        address _registryCoordinator,
        address _stakeRegistry
    ) external;

    /**
     * @notice Updates the metadata URI for the AVS
     * @param _metadataURI is the metadata URI for the AVS
     * @dev only callable by the owner
     */
    function updateAVSMetadataURI(string memory _metadataURI) external;

    /**
     * @notice Creates a new rewards submission to the EigenLayer RewardsCoordinator contract, to be split amongst the
     * set of stakers delegated to operators who are registered to this `avs`
     * @param rewardsSubmissions The rewards submissions being created
     * @dev Only callable by the permissioned rewardsInitiator address
     * @dev The duration of the `rewardsSubmission` cannot exceed `MAX_REWARDS_DURATION`
     * @dev The tokens are sent to the `RewardsCoordinator` contract
     * @dev Strategies must be in ascending order of addresses to check for duplicates
     * @dev This function will revert if the `rewardsSubmission` is malformed,
     * e.g. if the `strategies` and `weights` arrays are of non-equal lengths
     * @dev This function may fail to execute with a large number of submissions due to gas limits. Use a
     * smaller array of submissions if necessary.
     */

    /**
     * @notice Distributes rewards to the agent
     * @param _agent The agent to distribute rewards to
     * @param _token The token to distribute rewards for
     */
    function distributeRewards(address _agent, address _token) external;

    /**
     * @notice Returns the slashable collateral for an operator
     * @param operator The operator to get the slashable collateral for
     * @param timestamp The timestamp to get the slashable collateral for (unused for eigenlayer)
     * @return The slashable collateral of the operator
     */
    function slashableCollateral(address operator, uint256 timestamp) external view returns (uint256);
}
