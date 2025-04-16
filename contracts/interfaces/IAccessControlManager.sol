// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IAccessControlManager
/// @author @capLabs
/// @notice Interface for AccessControlManager contract
interface IAccessControlManager {
    /// @notice Role access struct
    /// @param selector Function selector
    /// @param contractAddress Contract address
    struct RoleAccess {
        bytes4 selector;
        address contractAddress;
    }

    /// @notice Role struct
    /// @param id Role id
    /// @param accesses List of role accesses
    struct Role {
        string id;
        RoleAccess[] accesses;
    }

    /// @custom:storage-location erc7201:cap.storage.AccessControlManager
    struct AccessControlManagerStorage {
        address accessControl;
        EnumerableSet.Bytes32Set roleNames; // Store hashed role names for enumeration
        mapping(bytes32 => string) roleNamesByHash; // Maps hash => original string name
        mapping(bytes32 => EnumerableSet.Bytes32Set) roleAccesses; // Maps role hash => set of access IDs (encoded with RoleId)
        mapping(bytes32 => EnumerableSet.AddressSet) roleAddresses; // Maps role hash => set of addresses that have the role
    }

    /// @notice Initialize the access control manager
    /// @param _accessControl Access control contract address
    /// @param _admin Default admin address
    function initialize(address _accessControl, address _admin) external;

    /// @notice Create a new role with initial accesses
    /// @param _role Role id
    /// @param _accesses Initial set of accesses for the role
    /// @dev Reverts if the role already exists
    function createRole(string calldata _role, RoleAccess[] calldata _accesses) external;

    /// @notice Grant a specific role to an address
    /// @param _role Role id
    /// @param _address Address to grant role to
    function grantRole(string calldata _role, address _address) external;

    /// @notice Revoke a specific role from an address
    /// @param _role Role id
    /// @param _address Address to revoke role from
    function revokeRole(string calldata _role, address _address) external;

    /// @notice Check if an address has a specific role
    /// @param _role Role id
    /// @param _address Address to check role for
    /// @return hasRole True if the address has the role, false otherwise
    function hasRole(string calldata _role, address _address) external view returns (bool hasRole);

    /// @notice List all addresses with a specific role
    /// @param _role Role id
    /// @return addresses List of addresses with the role
    function addressesWithRole(string calldata _role) external view returns (address[] memory addresses);

    /// @notice List all roles
    /// @return roles List of roles
    function roles() external view returns (Role[] memory roles);

    /// @notice List all accesses for a role
    /// @param _role Role id
    /// @return role Role struct
    function role(string calldata _role) external view returns (Role memory role);

    /// @notice Update a role, adding a new access, updating all users with the role
    /// @param _role Role id
    /// @param _access New access to add
    function addRoleAccess(string calldata _role, RoleAccess calldata _access) external;

    /// @notice Remove an access from a role, updating all users with the role
    /// @param _role Role id
    /// @param _access Access to remove
    function removeRoleAccess(string calldata _role, RoleAccess calldata _access) external;
}
