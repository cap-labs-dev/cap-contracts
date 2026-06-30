// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ILender } from "../interfaces/ILender.sol";

/// @title Lender Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Lender
abstract contract LenderStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Lender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LENDER_STORAGE_LOCATION =
        0xd6af1ec8a1789f5ada2b972bd1569f7c83af2e268be17cd65efe8474ebf08800;

    /// @dev Get Lender storage
    /// @return $ Storage pointer
    function getLenderStorage() internal pure returns (ILender.Storage storage $) {
        assembly {
            $.slot := LENDER_STORAGE_LOCATION
        }
    }
}
