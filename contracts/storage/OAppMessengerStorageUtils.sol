// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOAppMessenger } from "../interfaces/IOAppMessenger.sol";

/// @title OAppMessengerStorageUtils
/// @author @capLabs
/// @notice Storage utilities for OAppMessenger contract
contract OAppMessengerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.OAppMessenger")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant OAppMessengerStorageLocation = 0x628557c79d910c34916c539c6f7abd42659d54670171ff89f3d9c387b6f04300;

    /// @notice Get OAppMessenger storage
    /// @return $ Storage pointer
    function getOAppMessengerStorage() internal pure returns (IOAppMessenger.OAppMessengerStorage storage $) {
        assembly {
            $.slot := OAppMessengerStorageLocation
        }
    }
}
