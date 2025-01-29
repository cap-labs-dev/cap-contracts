// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Vault storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library VaultStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultStorageLocation = 0xe912a1b0cc7579bc5827e495c2ce52587bc3871751e3281fc5599b38c3bfc400;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.VaultStorage storage $) {
        assembly {
            $.slot := VaultStorageLocation
        }
    }
}
