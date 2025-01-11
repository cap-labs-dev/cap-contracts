// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAccessControl } from "../interfaces/IAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title AccessUpgradeable
/// @author kexley, @capLabs
/// @notice Inheritable access
contract AccessUpgradeable is Initializable {
    /// @custom:storage-location erc7201:cap.storage.Access
    struct AccessStorage {
        address accessControl;
    }

    // keccak256(abi.encode(uint256(keccak256("cap.storage.Access")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessStorageLocation = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;

    function _getAccessStorage() private pure returns (AccessStorage storage $) {
        assembly {
            $.slot := AccessStorageLocation
        }
    }

    /// @dev Initialize the access control address
    function __Access_init(address _accessControl) internal onlyInitializing {
        __Access_init_unchained(_accessControl);
    }

    function __Access_init_unchained(address _accessControl) internal onlyInitializing {
        AccessStorage storage $ = _getAccessStorage();
        $.accessControl = _accessControl;
    }

    /// @dev Check caller has permissions for a function
    /// @param _selector Function selector
    modifier checkAccess(bytes4 _selector) {
        _checkAccess(_selector);
        _;
    }

    /// @dev Check caller has access to a function, revert overwise
    /// @param _selector Function selector
    function _checkAccess(bytes4 _selector) internal view {
        AccessStorage storage $ = _getAccessStorage();
        IAccessControl($.accessControl).checkAccess(_selector, address(this), msg.sender);
    }
}
