// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAccessControlManager } from "../interfaces/IAccessControlManager.sol";

/// @title Access Storage Utils
/// @author @capLabs
/// @notice Storage utilities for access control
abstract contract AccessControlManagerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.AccessControlManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessControlManagerStorageLocation =
        0xa8e55fa73d63dcca5917b233a718aa54164700c7d59f099b897e389b6f7fe900;

    /// @dev Get access storage
    /// @return $ Storage pointer
    function getAccessControlManagerStorage()
        internal
        pure
        returns (IAccessControlManager.AccessControlManagerStorage storage $)
    {
        assembly {
            $.slot := AccessControlManagerStorageLocation
        }
    }
}
