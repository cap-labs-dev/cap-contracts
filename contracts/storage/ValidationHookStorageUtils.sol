// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IValidationHook } from "../interfaces/IValidationHook.sol";

/// @title Validation Hook Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for validation hook
abstract contract ValidationHookStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.ValidationHook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ValidationHookStorageLocation =
        0x7f7704a33af6a3d21bb2250ea2921f91d10c17ce89c128ab9d15747873f65300;

    /// @dev Get validation hook storage
    /// @return $ Storage pointer
    function getValidationHookStorage() internal pure returns (IValidationHook.ValidationHookStorage storage $) {
        assembly {
            $.slot := ValidationHookStorageLocation
        }
    }
}
