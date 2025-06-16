// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Oracle Types
/// @author kexley, @capLabs
/// @notice Oracle types
interface IOracleTypes {
    /// @notice Oracle data
    struct OracleData {
        address adapter;
        bytes payload;
    }
}
