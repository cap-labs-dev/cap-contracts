// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IEigenServiceManager {
    /// @dev EigenServiceManager storage
    /// @param accessControl Access control address
    struct EigenServiceManagerStorage {
        address accessControl;
        address avsDirectory;
        address rewardsCoordinator;
        address registryCoordinator;
        address stakeRegistry;
    }

    /// @notice Initialize the EigenServiceManager
    /// @param _accessControl Access control contract
    /// @param _avsDirectory AVS Directory contract
    /// @param _rewardsCoordinator Rewards Coordinator contract
    /// @param _registryCoordinator Registry Coordinator contract
    /// @param _stakeRegistry Stake Registry contract
    function initialize(
        address _accessControl,
        address _avsDirectory,
        address _rewardsCoordinator,
        address _registryCoordinator,
        address _stakeRegistry
    ) external;
}
