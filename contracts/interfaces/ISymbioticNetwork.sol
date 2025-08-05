// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISymbioticNetwork
/// @author weso, Cap Labs
/// @notice Interface for Symbiotic Network contract
interface ISymbioticNetwork {
    /// @dev Symbiotic network storage
    /// @param middleware Middleware contract
    /// @param networkOptInService Network opt-in service contract
    /// @param vaultOptInService Vault opt-in service contract
    /// @param operatorRegistry Operator registry contract
    /// @param operatorImplementation Operator implementation contract
    /// @param agentToOperator Mapping of agent to operator
    struct SymbioticNetworkStorage {
        address middleware;
        address networkOptInService;
        address vaultOptInService;
        address operatorRegistry;
        address operatorImplementation;
        mapping(address => address) agentToOperator;
    }

    /// @notice Initialize the Symbiotic network
    /// @param _accessControl Access control address
    /// @param _networkRegistry Network registry address
    /// @param _operatorRegistry Operator registry address
    /// @param _networkOptInService Network opt-in service address
    /// @param _vaultOptInService Vault opt-in service address
    /// @param _middleware Middleware contract

    function initialize(
        address _accessControl,
        address _networkRegistry,
        address _operatorRegistry,
        address _networkOptInService,
        address _vaultOptInService,
        address _middleware,
        address _middlewareService
    ) external;

    /// @notice Register vault with Symbiotic
    /// @param _vault Vault address
    /// @param _agent Agent address
    function registerVault(address _vault, address _agent) external;

    /// @notice Get operator address
    /// @param _agent Agent address
    /// @return operator address
    function getOperator(address _agent) external view returns (address);

    /// @notice Deploy operator contract
    /// @param _agent Agent address
    /// @return operator address
    function deployOperator(address _agent) external returns (address operator);
}
