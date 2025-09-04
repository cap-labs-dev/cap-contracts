// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IEigenOperator {
    /// @dev Error thrown when the caller is not the service manager
    error NotServiceManager();
    /// @dev Error thrown when the caller is not the operator
    error NotOperator();
    /// @dev Error thrown when the operator is already allocated to a strategy
    error AlreadyAllocated();

    /// @dev EigenOperator storage
    /// @param serviceManager EigenServiceManager address
    /// @param operator Eigen operator address
    /// @param allocationManager EigenCloud Allocation manager address
    /// @param delegationManager EigenCloud Delegation manager address
    /// @param rewardsCoordinator EigenCloud Rewards coordinator address
    struct EigenOperatorStorage {
        address serviceManager;
        address operator;
        address allocationManager;
        address delegationManager;
        address rewardsCoordinator;
    }

    /// @notice Initialize the EigenOperator
    /// @param _serviceManager EigenServiceManager address
    /// @param _operator Eigen operator address
    function initialize(address _serviceManager, address _operator, string calldata _metadata) external;

    /// @notice Register an operator set to the service manager
    /// @param _operatorSetId Operator set id
    function registerOperatorSetToServiceManager(uint32 _operatorSetId) external;

    /// @notice Update the operator metadata URI
    /// @param _metadataURI The new metadata URI
    function updateOperatorMetadataURI(string calldata _metadataURI) external;

    /// @notice Allocate the operator set to the strategy, called by service manager.
    /// @param _operatorSetId Operator set id
    /// @param _strategy Strategy address
    function allocate(uint32 _operatorSetId, address _strategy) external;

    /// @notice Get the service manager
    /// @return The service manager address
    function eigenServiceManager() external view returns (address);

    /// @notice Get the operator
    /// @return The operator or borrower address in the cap system
    function operator() external view returns (address);
}
