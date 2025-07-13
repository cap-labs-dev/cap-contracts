// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISymbioticNetwork
/// @author weso, Cap Labs
/// @notice Interface for Symbiotic Network contract
interface ISymbioticNetwork {
    /// @dev Symbiotic network storage
    /// @param middleware Middleware contract
    struct SymbioticNetworkStorage {
        address middleware;
    }

    /// @notice Initialize the Symbiotic network
    /// @param _accessControl Access control address
    /// @param _networkRegistry Network registry address
    function initialize(address _accessControl, address _networkRegistry) external;

    /// @notice Register middleware contract
    /// @param _middleware Middleware contract
    /// @param _middlewareService Middleware service address
    function registerMiddleware(address _middleware, address _middlewareService) external;

    /// @notice Register vault with Symbiotic
    /// @param _vault Vault address
    function registerVault(address _vault) external;
}
