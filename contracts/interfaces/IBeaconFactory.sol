// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IBeaconFactory
/// @author kexley, Cap Labs
/// @notice Interface for deploying and initializing beacon proxies
interface IBeaconFactory {
    /// @notice Emitted when a beacon proxy is deployed
    /// @param beacon The upgradeable beacon the proxy follows
    /// @param proxy The address of the deployed beacon proxy
    event Deployed(address indexed beacon, address indexed proxy);

    /// @notice Initialize the factory
    /// @param authority The access manager address
    function initialize(address authority) external;

    /// @notice Deploy a beacon proxy and initialize it with the given data
    /// @param beacon The upgradeable beacon for the proxy implementation
    /// @param data The initialization calldata for the proxy
    /// @return proxy The address of the deployed beacon proxy
    function create(address beacon, bytes memory data) external returns (address proxy);
}
