// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ISymbioticAgentManager {
    /// @dev SymbioticAgentManager storage
    /// @param delegation Delegation address
    /// @param networkMiddleware Network middleware address
    /// @param oracle Oracle address
    struct SymbioticAgentManagerStorage {
        address delegation;
        address networkMiddleware;
        address oracle;
    }

    struct AgentConfig {
        address agent;
        address vault;
        address rewarder;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 delegationRate;
    }

    /// @notice Initialize the agent manager
    /// @param _accessControl Access control address
    /// @param _delegation Delegation address
    /// @param _network Network address
    /// @param _oracle Oracle address
    function initialize(address _accessControl, address _delegation, address _network, address _oracle) external;

    /// @notice Add an agent to the agent manager
    /// @param _agentConfig Agent configuration
    function addAgent(AgentConfig calldata _agentConfig) external;
}
