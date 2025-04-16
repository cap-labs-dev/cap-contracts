// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAccessControl } from "../interfaces/IAccessControl.sol";

import { RoleId } from "./RoleId.sol";
import { AccessControlEnumerableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessControl
/// @author kexley, @capLabs
/// @notice Granular access control for each function on each contract
contract AccessControl is IAccessControl, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    using RoleId for bytes32;
    using RoleId for bytes4;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the default admin
    /// @param _admin Default admin address
    function initialize(address _admin) external initializer {
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(this.grantAccess.selector.roleId(address(this)), _admin);
        _grantRole(this.revokeAccess.selector.roleId(address(this)), _admin);
    }

    /// @notice Check if an address has access to a specific method on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _caller Address to check role for
    function checkAccess(bytes4 _selector, address _contract, address _caller) external view {
        _checkRole(_selector.roleId(_contract), _caller);
    }

    /// @notice Fetch if an address has access to a specific method on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _caller Address to check role for
    /// @return hasAccess True if the address has access, false otherwise
    function hasAccess(bytes4 _selector, address _contract, address _caller) external view returns (bool) {
        return hasRole(_selector.roleId(_contract), _caller);
    }

    /// @notice Grant access to a specific method on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _address Address to grant role to
    function grantAccess(bytes4 _selector, address _contract, address _address) external {
        _checkRole(this.grantAccess.selector.roleId(address(this)), msg.sender);
        _grantRole(_selector.roleId(_contract), _address);
    }

    /// @notice Revoke access to a specific method on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _address Address to revoke role from
    function revokeAccess(bytes4 _selector, address _contract, address _address) external {
        _checkRole(this.revokeAccess.selector.roleId(address(this)), msg.sender);

        if (_address == msg.sender && _contract == address(this)) revert CannotRevokeSelf();

        _revokeRole(_selector.roleId(_contract), _address);
    }

    /// @notice Fetch role id for a function selector on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @return roleId Role id
    function role(bytes4 _selector, address _contract) external pure returns (bytes32 roleId) {
        roleId = _selector.roleId(_contract);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
