// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IUpgradeableBeacon} from "../../interfaces/IUpgradeableBeacon.sol";

/// @title CloneLogic library
/// @author kexley
/// @notice Implements the base logic for all the actions related to cloning
library CloneLogic {
    /// @dev New instance has been created
    event InstanceCreated(address indexed implementation, address instance);

    /// @dev New proxy has been created
    event ProxyCreated(address indexed proxy, address instance);

    /// @dev Instance has been upgraded
    event Upgrade(address indexed instance, address implementation);

    /// @notice Initialize an upgradeable beacon owned by the pool
    /// @param _implementation Implementation address
    /// @return instance Created upgradeable beacon instance
    function initializeBeacon(address _implementation) external returns (address instance) {
        instance = address(new UpgradeableBeacon(_implementation, address(this)));
        emit InstanceCreated(_implementation, instance);
    }

    /// @notice Clone a contract using an upgradeable beacon proxy
    /// @param _instance Address of the instance to clone
    /// @return proxy Address of the created proxy
    function clone(address _instance) external returns (address proxy) {
        proxy = address(new BeaconProxy(_instance, ""));
        emit ProxyCreated(_instance, proxy);
    }

    /// @notice Upgrade the implementation on an instance
    /// @param _instance The instance to change implementation on
    /// @param _implementation The address of the new implementation
    function upgradeTo(address _instance, address _implementation) external {
        IUpgradeableBeacon(_instance).upgradeTo(_implementation);
        emit Upgrade(_instance, _implementation);
    }
}
