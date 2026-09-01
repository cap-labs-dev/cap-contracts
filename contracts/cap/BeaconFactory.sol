// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBeaconFactory } from "../interfaces/IBeaconFactory.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title BeaconFactory
/// @author kexley, Cap Labs
/// @notice Deploy and initialize beacon proxies for any registered beacon
contract BeaconFactory layout at erc7201("cap.storage.BeaconFactory")
    is
    IBeaconFactory,
    AccessManagedUpgradeable,
    UUPSUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IBeaconFactory
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    /// @inheritdoc IBeaconFactory
    function create(address beacon, bytes memory data) external restricted returns (address proxy) {
        proxy = address(new BeaconProxy(beacon, data));
        emit Deployed(proxy);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
