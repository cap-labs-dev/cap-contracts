// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISymbioticOperator
/// @author weso, Cap Labs
/// @notice Interface for Symbiotic Operator contract
interface ISymbioticOperator {
    struct SymbioticOperatorStorage {
        address agent;
        address network;
    }

    /// @notice Initialize the Symbiotic operator
    /// @param _agent Agent address
    /// @param _optInService Opt-in service address
    /// @param _operatorRegistry Operator registry address
    /// @param _network Network address
    function initialize(address _agent, address _optInService, address _operatorRegistry, address _network) external;

    /// @notice Opt into vault
    /// @param _vaultOptInService Vault opt-in service address
    /// @param _vault Vault address
    function optIntoVault(address _vaultOptInService, address _vault) external;
}
