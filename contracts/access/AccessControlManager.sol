// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";

import { RoleId } from "../access/RoleId.sol";
import { IAccessControl } from "../interfaces/IAccessControl.sol";
import { IAccessControlManager } from "../interfaces/IAccessControlManager.sol";
import { AccessControlManagerStorageUtils } from "../storage/AccessControlManagerStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Access Control Manager
/// @author @capLabs
/// @notice Manage access control for the contracts
contract AccessControlManager is UUPSUpgradeable, AccessControlManagerStorageUtils, IAccessControlManager, Access {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using RoleId for bytes32;
    using RoleId for bytes4;

    /// @dev Critical role and permission constants
    string internal constant ROLE_MANAGER_ADMIN = "ROLE_MANAGER_ADMIN";

    /// @dev Custom errors for permission checks
    error NoRemainingAdmins();
    error CriticalPermissionRemoved();
    error CriticalRoleAccessRemoved();

    /// @dev Events for single access operations
    event RoleAccessAdded(string indexed role, RoleAccess access);
    event RoleAccessRemoved(string indexed role, RoleAccess access);
    event RoleCreated(string indexed role, RoleAccess[] accesses);

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the access control manager
    /// @param _accessControl The access control contract address
    /// @param _admin The admin address
    function initialize(address _accessControl, address _admin) external initializer {
        __Access_init(_accessControl);

        IAccessControl ac = IAccessControl(_accessControl);
        // require this contract to be able grant and revoke access
        ac.checkAccess(bytes4(0), address(0), address(this)); // DEFAULT_ADMIN_ROLE from openzeppelin
        ac.checkAccess(ac.grantAccess.selector, _accessControl, address(this));
        ac.checkAccess(ac.revokeAccess.selector, _accessControl, address(this));

        // Store access control address
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        s.accessControl = _accessControl;

        // Grant role management access to self
        RoleAccess[] memory access = _roleManagerAdminMinimalAccesses();
        _createRole(ROLE_MANAGER_ADMIN, access);
        _grantRole(ROLE_MANAGER_ADMIN, _admin);

        _checkCriticalPermissions();
    }

    /// ===================================================
    /// ============ Role management functions ============
    /// ===================================================

    /// @notice Create a new role with initial accesses
    /// @param _role Role id
    /// @param _accesses Initial set of accesses for the role
    /// @dev Reverts if the role already exists
    function createRole(string calldata _role, RoleAccess[] calldata _accesses)
        external
        checkAccess(this.createRole.selector)
    {
        _createRole(_role, _accesses);
    }

    /// @notice Update a role, adding a new access, updating all users with the role
    /// @param _role Role id
    /// @param _access New access to add
    function addRoleAccess(string calldata _role, RoleAccess calldata _access)
        external
        checkAccess(this.addRoleAccess.selector)
    {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        bytes32 roleHash = _roleToHash(_role);

        // Add role to roles array if it doesn't exist yet
        if (!s.roleNames.contains(roleHash)) {
            s.roleNames.add(roleHash);
            s.roleNamesByHash[roleHash] = _role;
        }

        // Add access to role
        bytes32 accessId = _access.selector.roleId(_access.contractAddress);
        if (s.roleAccesses[roleHash].add(accessId)) {
            // Grant this access to all addresses with this role
            uint256 addressCount = s.roleAddresses[roleHash].length();
            for (uint256 j = 0; j < addressCount; j++) {
                address addr = s.roleAddresses[roleHash].at(j);
                ac.grantAccess(_access.selector, _access.contractAddress, addr);
            }

            emit RoleAccessAdded(_role, _access);
        }
    }

    /// @notice Remove an access from a role, updating all users with the role
    /// @param _role Role id
    /// @param _access Access to remove
    function removeRoleAccess(string calldata _role, RoleAccess calldata _access)
        external
        checkAccess(this.removeRoleAccess.selector)
    {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        bytes32 roleHash = _roleToHash(_role);
        bytes32 accessId = RoleId.roleId(_access.selector, _access.contractAddress);

        if (s.roleAccesses[roleHash].remove(accessId)) {
            // Revoke this access from all addresses with this role
            uint256 addressCount = s.roleAddresses[roleHash].length();
            for (uint256 j = 0; j < addressCount; j++) {
                address addr = s.roleAddresses[roleHash].at(j);
                ac.revokeAccess(_access.selector, _access.contractAddress, addr);
            }

            emit RoleAccessRemoved(_role, _access);
        }

        // Check if we've removed a critical permission
        _checkCriticalPermissions();
    }

    /// ===================================================
    /// ============ Role Assignment functions ============
    /// ===================================================

    /// @notice Grant a specific role to an address
    /// @param _role Role id
    /// @param _address Address to grant role to
    function grantRole(string calldata _role, address _address) external checkAccess(this.grantRole.selector) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        bytes32 roleHash = _roleToHash(_role);

        // Store the string role name mapped to its hash if not already stored
        if (!s.roleNames.contains(roleHash)) {
            s.roleNames.add(roleHash);
            s.roleNamesByHash[roleHash] = _role;
        }

        // Add address to role if not already added
        if (s.roleAddresses[roleHash].add(_address)) {
            // Grant access for each function selector in the role
            uint256 count = s.roleAccesses[roleHash].length();
            for (uint256 i = 0; i < count; i++) {
                bytes32 accessId = s.roleAccesses[roleHash].at(i);
                (bytes4 selector, address contractAddr) = accessId.decodeRoleId();
                ac.grantAccess(selector, contractAddr, _address);
            }
        }
    }

    /// @notice Revoke a specific role from an address
    /// @param _role Role id
    /// @param _address Address to revoke role from
    function revokeRole(string calldata _role, address _address) external checkAccess(this.revokeRole.selector) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        bytes32 roleHash = _roleToHash(_role);

        // Remove address from role
        if (s.roleAddresses[roleHash].remove(_address)) {
            // Revoke access for each function selector in the role
            uint256 count = s.roleAccesses[roleHash].length();
            for (uint256 i = 0; i < count; i++) {
                bytes32 accessId = s.roleAccesses[roleHash].at(i);
                (bytes4 selector, address contractAddr) = accessId.decodeRoleId();
                ac.revokeAccess(selector, contractAddr, _address);
            }
        }

        // Check if we've removed a critical permission
        _checkCriticalPermissions();
    }

    /// ===================================================
    /// ============ Role auditing functions ============
    /// ===================================================

    /// @notice Check if an address has a specific role
    /// @param _role Role id
    /// @param _address Address to check role for
    /// @return hasRole True if the address has the role, false otherwise
    function hasRole(string calldata _role, address _address) public view returns (bool) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        bytes32 roleHash = _roleToHash(_role);
        return s.roleAddresses[roleHash].contains(_address);
    }

    /// @notice List all addresses with a specific role
    /// @param _role Role id
    /// @return addresses List of addresses with the role
    function addressesWithRole(string calldata _role) external view returns (address[] memory) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        bytes32 roleHash = _roleToHash(_role);
        uint256 count = s.roleAddresses[roleHash].length();
        address[] memory result = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = s.roleAddresses[roleHash].at(i);
        }

        return result;
    }

    /// @notice List all roles
    /// @return roles List of roles
    function roles() external view returns (Role[] memory) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        uint256 count = s.roleNames.length();
        Role[] memory result = new Role[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 roleHash = s.roleNames.at(i);
            string memory roleName = s.roleNamesByHash[roleHash];
            result[i] = Role({ id: roleName, accesses: _getRoleAccesses(s, roleHash) });
        }

        return result;
    }

    /// @notice List all accesses for a role
    /// @param _role Role id
    /// @return role Role with its accesses
    function role(string calldata _role) external view returns (Role memory) {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        bytes32 roleHash = _roleToHash(_role);
        return Role({ id: _role, accesses: _getRoleAccesses(s, roleHash) });
    }

    /// ===================================================
    /// ============ Internal helper functions ============
    /// ===================================================

    /// @dev Helper to convert string role to bytes32 hash for storage
    function _roleToHash(string memory _role) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_role));
    }

    /// @dev Internal function to create a new role with initial accesses
    function _createRole(string memory _role, RoleAccess[] memory _accesses) internal {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        bytes32 roleHash = _roleToHash(_role);

        // Check if role already exists
        require(!s.roleNames.contains(roleHash), "Role already exists");

        // Add role to storage
        s.roleNames.add(roleHash);
        s.roleNamesByHash[roleHash] = _role;

        // Add all initial accesses
        for (uint256 i = 0; i < _accesses.length; i++) {
            RoleAccess memory access = _accesses[i];
            bytes32 accessId = access.selector.roleId(access.contractAddress);
            s.roleAccesses[roleHash].add(accessId);

            // We don't need to grant access to any address yet,
            // since no addresses have this role at creation time
        }

        emit RoleCreated(_role, _accesses);
    }

    /// @dev Grant a role to an address by its string name
    /// @param _role Role name as string
    /// @param _address Address to grant role to
    function _grantRole(string memory _role, address _address) internal {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        bytes32 roleHash = keccak256(abi.encodePacked(_role));

        // Store the string role name mapped to its hash if not already stored
        if (!s.roleNames.contains(roleHash)) {
            s.roleNames.add(roleHash);
            s.roleNamesByHash[roleHash] = _role;
        }

        // Add address to role if not already added
        if (s.roleAddresses[roleHash].add(_address)) {
            // Grant access for each function selector in the role
            uint256 count = s.roleAccesses[roleHash].length();
            for (uint256 i = 0; i < count; i++) {
                bytes32 accessId = s.roleAccesses[roleHash].at(i);
                (bytes4 selector, address contractAddr) = accessId.decodeRoleId();
                ac.grantAccess(selector, contractAddr, _address);
            }
        }
    }

    /// @dev Get all accesses for a role
    /// @param _s Storage reference
    /// @param _roleHash Role hash ID
    /// @return accesses Array of RoleAccess structs
    function _getRoleAccesses(AccessControlManagerStorage storage _s, bytes32 _roleHash)
        internal
        view
        returns (RoleAccess[] memory)
    {
        uint256 count = _s.roleAccesses[_roleHash].length();
        RoleAccess[] memory accesses = new RoleAccess[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 accessId = _s.roleAccesses[_roleHash].at(i);
            (bytes4 selector, address contractAddr) = accessId.decodeRoleId();
            accesses[i] = RoleAccess({ selector: selector, contractAddress: contractAddr });
        }

        return accesses;
    }

    /// @dev Ensures critical permissions are not removed
    /// 1. This contract must always have grantAccess and revokeAccess permissions on AC
    /// 2. There must always be at least one non-zero ROLE_MANAGER_ADMIN
    /// 3. ROLE_MANAGER_ADMIN must retain all critical accesses defined in initialize
    function _checkCriticalPermissions() internal view {
        AccessControlManagerStorage storage s = getAccessControlManagerStorage();
        IAccessControl ac = IAccessControl(s.accessControl);

        // Check if this contract has grant and revoke permissions
        if (!ac.hasAccess(bytes4(0), address(0), address(this))) {
            revert CriticalPermissionRemoved();
        }

        if (!ac.hasAccess(ac.grantAccess.selector, address(ac), address(this))) {
            revert CriticalPermissionRemoved();
        }

        if (!ac.hasAccess(ac.revokeAccess.selector, address(ac), address(this))) {
            revert CriticalPermissionRemoved();
        }

        // Check if there's at least one non-zero admin address
        bytes32 adminRoleHash = _roleToHash(ROLE_MANAGER_ADMIN);
        uint256 adminCount = s.roleAddresses[adminRoleHash].length();

        if (adminCount == 0) {
            revert NoRemainingAdmins();
        }

        // Additional check to ensure there's at least one non-zero address
        bool hasNonZeroAdmin = false;
        for (uint256 i = 0; i < adminCount; i++) {
            address admin = s.roleAddresses[adminRoleHash].at(i);
            if (admin != address(0)) {
                hasNonZeroAdmin = true;
                break;
            }
        }

        if (!hasNonZeroAdmin) {
            revert NoRemainingAdmins();
        }

        // Check that ROLE_MANAGER_ADMIN role maintains all critical accesses
        RoleAccess[] memory criticalAccessIds = _roleManagerAdminMinimalAccesses();
        for (uint256 i = 0; i < criticalAccessIds.length; i++) {
            bytes32 accessId = criticalAccessIds[i].selector.roleId(criticalAccessIds[i].contractAddress);
            if (!s.roleAccesses[adminRoleHash].contains(accessId)) {
                revert CriticalRoleAccessRemoved();
            }
        }
    }

    function _roleManagerAdminMinimalAccesses() internal view returns (RoleAccess[] memory) {
        RoleAccess[] memory criticalAccessIds = new RoleAccess[](7);
        criticalAccessIds[0] = RoleAccess({ selector: this.grantRole.selector, contractAddress: address(this) });
        criticalAccessIds[1] = RoleAccess({ selector: this.revokeRole.selector, contractAddress: address(this) });
        criticalAccessIds[2] = RoleAccess({ selector: this.addRoleAccess.selector, contractAddress: address(this) });
        criticalAccessIds[3] = RoleAccess({ selector: this.removeRoleAccess.selector, contractAddress: address(this) });
        criticalAccessIds[4] = RoleAccess({ selector: this.createRole.selector, contractAddress: address(this) });
        criticalAccessIds[5] = RoleAccess({ selector: this.upgradeToAndCall.selector, contractAddress: address(this) });
        criticalAccessIds[6] = RoleAccess({ selector: bytes4(0), contractAddress: address(this) });
        return criticalAccessIds;
    }

    /// ===================================================
    /// ============ UUPSUpgradeable functions ============
    /// ===================================================

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
