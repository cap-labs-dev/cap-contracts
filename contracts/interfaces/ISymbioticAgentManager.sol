// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ISymbioticAgentManager {
    /// @dev SymbioticAgentManager storage
    /// @param delegation Delegation address
    /// @param networkMiddleware Network middleware address
    /// @param oracle Oracle address
    /// @param lender Lender address
    /// @param cUSD Token address
    struct SymbioticAgentManagerStorage {
        address delegation;
        address networkMiddleware;
        address oracle;
        address lender;
        address cusd;
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
    /// @param _lender Lender address
    /// @param _cusd cUSD token address
    /// @param _delegation Delegation address
    /// @param _networkMiddleware Network middleware address
    /// @param _oracle Oracle address
    function initialize(
        address _accessControl,
        address _lender,
        address _cusd,
        address _delegation,
        address _networkMiddleware,
        address _oracle
    ) external;

    /// @notice Add an agent to the agent manager
    /// @param _agentConfig Agent configuration
    function addAgent(AgentConfig calldata _agentConfig) external;

    /// @notice Set the restaker rate for an agent
    /// @param _agent Agent address
    /// @param _delegationRate Delegation rate
    function setRestakerRate(address _agent, uint256 _delegationRate) external;
}
