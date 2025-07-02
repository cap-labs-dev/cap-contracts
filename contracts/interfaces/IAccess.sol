// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IAccess
/// @author kexley, Cap Labs
/// @notice Interface for Access contract
interface IAccess {
    /// @dev Access storage
    /// @param accessControl Access control address
    struct AccessStorage {
        address accessControl;
    }

    /// @notice Access is denied for the caller
    error AccessDenied();
}
