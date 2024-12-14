// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CloneLogic library
/// @author kexley
/// @notice Implements the base logic for all the actions related to borrowing
library CloneLogic {
    /// @dev New instance has been created
    event InstanceCreated(address indexed implementation, address instance);

    /// @dev New proxy has been created
    event ProxyCreated(address indexed proxy, address instance);

    /// @dev Instance has been upgraded
    event Upgrade(address indexed instance, address implementation);

    /// @notice Initialize an upgradeable beacon owned by the pool
    /// @param implementation Implementation address
    /// @return instance Created upgradeable beacon instance
    function initializeBeacon(address implementation) external returns (address instance) {
        instance = address(new UpgradeableBeacon(_implementation, address(this)));
        emit InstanceCreated(implementation, instance);
    }

    /// @notice Clone a contract using an upgradeable beacon proxy
    /// @param instance Address of the instance to clone
    /// @return proxy Address of the created proxy
    function clone(address instance) external return (address proxy) {
        proxy = address(new BeaconProxy(instance, ""));
        emit ProxyCreated(instance, proxy);
    }

    /// @notice Upgrade the implementation on an instance
    /// @param instance The instance to change implementation on
    /// @param implementation The address of the new implementation
    function upgradeTo(address instance, address implementation) external {
        IUpgradeableBeacon(instance).upgradeTo(implementation);
        emit Upgrade(instance, implementation);
    }
}
