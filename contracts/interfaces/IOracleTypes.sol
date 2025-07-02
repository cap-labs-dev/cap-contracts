// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Oracle Types
/// @author kexley, Cap Labs
/// @notice Oracle types
interface IOracleTypes {
    /// @notice Oracle data
    /// @param adapter Adapter address
    /// @param payload Payload for the adapter
    struct OracleData {
        address adapter;
        bytes payload;
    }
}
