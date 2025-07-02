// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAccessControl } from "../interfaces/IAccessControl.sol";
import { AccessControlEnumerableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessControl
/// @author kexley, Cap Labs
/// @notice Granular access control for each function on each contract
contract AccessControl is IAccessControl, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IAccessControl
    function initialize(address _admin) external initializer {
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(role(this.grantAccess.selector, address(this)), _admin);
        _grantRole(role(this.revokeAccess.selector, address(this)), _admin);
    }

    /// @inheritdoc IAccessControl
    function grantAccess(bytes4 _selector, address _contract, address _address) external {
        _checkRole(role(this.grantAccess.selector, address(this)), msg.sender);
        _grantRole(role(_selector, _contract), _address);
    }

    /// @inheritdoc IAccessControl
    function revokeAccess(bytes4 _selector, address _contract, address _address) external {
        bytes32 roleId = role(this.revokeAccess.selector, address(this));
        _checkRole(roleId, msg.sender);

        bytes32 roleIdToRevoke = role(_selector, _contract);
        if (_address == msg.sender && roleIdToRevoke == roleId) revert CannotRevokeSelf();

        _revokeRole(roleIdToRevoke, _address);
    }

    /// @inheritdoc IAccessControl
    function checkAccess(bytes4 _selector, address _contract, address _caller) external view returns (bool hasAccess) {
        _checkRole(role(_selector, _contract), _caller);
        hasAccess = true;
    }

    /// @inheritdoc IAccessControl
    function role(bytes4 _selector, address _contract) public pure returns (bytes32 roleId) {
        roleId = bytes32(_selector) | bytes32(uint256(uint160(_contract)));
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
