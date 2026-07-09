// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title BeaconFactory
/// @author kexley
/// @notice Deploy and initialize beacon proxies
contract BeaconFactory {
    /// @notice Emitted when a beacon proxy is deployed
    /// @param proxy The address of the deployed beacon proxy
    event Deployed(address proxy);

    /// @notice Mapping of deployed beacon proxies
    mapping(address proxy => bool) public isDeployed;

    /// @notice The beacon contract address
    address public beacon;

    /// @notice Constructor for the beacon factory
    /// @param _beacon The beacon contract address
    constructor(address _beacon) {
        beacon = _beacon;
    }

    /// @notice Deploy a beacon proxy and initialize it with the given data
    /// @param data The initialization data for the beacon proxy
    /// @return proxy The address of the deployed beacon proxy
    function create(bytes memory data) external returns (address proxy) {
        proxy = address(new BeaconProxy(beacon, data));
        isDeployed[proxy] = true;
        emit Deployed(proxy);
    }
}
