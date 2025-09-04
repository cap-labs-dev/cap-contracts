// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IEigenAgentManager {
    /// @dev EigenAgentManager storage
    /// @param delegation Delegation address
    /// @param serviceManager Service manager address
    /// @param oracle Oracle address
    /// @param lender Lender address
    /// @param cusd cUSD token address
    struct EigenAgentManagerStorage {
        address delegation;
        address serviceManager;
        address oracle;
        address lender;
        address cusd;
    }

    /// @dev Agent configuration
    /// @param agent Agent address
    /// @param strategy Strategy address
    /// @param avsMetadata AVS metadata
    /// @param operatorMetadata Operator metadata
    /// @param ltv LTV
    /// @param liquidationThreshold Liquidation threshold
    /// @param delegationRate Delegation rate
    struct AgentConfig {
        address agent;
        address strategy;
        string avsMetadata;
        string operatorMetadata;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 delegationRate;
    }

    /// @notice Initialize the agent manager
    /// @param _accessControl Access control address
    /// @param _lender Lender address
    /// @param _cusd cUSD token address
    /// @param _delegation Delegation address
    /// @param _serviceManager Service manager address
    /// @param _oracle Oracle address
    function initialize(
        address _accessControl,
        address _lender,
        address _cusd,
        address _delegation,
        address _serviceManager,
        address _oracle
    ) external;

    /// @notice Add an agent to the agent manager
    /// @param _agentConfig Agent configuration
    function addEigenAgent(AgentConfig calldata _agentConfig) external;

    /// @notice Set the restaker rate for an agent
    /// @param _agent Agent address
    /// @param _delegationRate Delegation rate
    function setRestakerRate(address _agent, uint256 _delegationRate) external;
}
