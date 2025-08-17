// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapNotify } from "../interfaces/ICapNotify.sol";

/// @title Cap Notify Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for cap notify
abstract contract CapNotifyStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapNotify")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapNotifyStorageLocation =
        0xae7da03710cf6ca7cf92719d8e00ba51842bad60a95a2e09406012de26726900;

    /// @dev Get cap notify storage
    /// @return $ Storage pointer
    function getCapNotifyStorage() internal pure returns (ICapNotify.CapNotifyStorage storage $) {
        assembly {
            $.slot := CapNotifyStorageLocation
        }
    }
}
