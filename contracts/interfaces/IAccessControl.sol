// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IAccessControl
/// @author kexley, Cap Labs
/// @notice Interface for granular access control system that manages permissions for specific function selectors on contracts
interface IAccessControl {
    /// @notice Error thrown when trying to revoke own revocation role
    error CannotRevokeSelf();

    /// @notice Initialize the access control system with a default admin
    /// @param _admin Address to be granted the default admin role and initial access management permissions
    function initialize(address _admin) external;

    /// @notice Grant access to a specific method on a contract
    /// @param _selector Function selector (4-byte identifier) of the method to grant access to
    /// @param _contract Address of the contract containing the method
    /// @param _address Address to grant access to
    function grantAccess(bytes4 _selector, address _contract, address _address) external;

    /// @notice Revoke access to a specific method on a contract
    /// @param _selector Function selector (4-byte identifier) of the method to revoke access from
    /// @param _contract Address of the contract containing the method
    /// @param _address Address to revoke access from
    function revokeAccess(bytes4 _selector, address _contract, address _address) external;

    /// @notice Check if a specific method access is granted to an address
    /// @param _selector Function selector (4-byte identifier) of the method to check
    /// @param _contract Address of the contract containing the method
    /// @param _caller Address to check permissions for
    /// @return hasAccess True if access is granted, false otherwise
    function checkAccess(bytes4 _selector, address _contract, address _caller) external view returns (bool hasAccess);

    /// @notice Get the role identifier for a specific function selector on a contract
    /// @dev The role identifier is a unique identifier derived packing the selector and contract address
    /// @param _selector Function selector (4-byte identifier) of the method
    /// @param _contract Address of the contract containing the method
    /// @return roleId Unique role identifier derived from the selector and contract address
    function role(bytes4 _selector, address _contract) external pure returns (bytes32 roleId);
}
