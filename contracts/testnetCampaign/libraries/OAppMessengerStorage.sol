// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./DataTypes.sol";

/// @title OAppMessenger storage pointer
/// @author kexley, @capLabs
library OAppMessengerStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.OAppMessengerStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OAppMessengerStorageLocation = 
        0x5ca010aef962caf809fe3d8a2fa62e9f02a6488e09128d8089b73210e8a1ea00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.OAppMessengerStorage storage $) {
        assembly {
            $.slot := OAppMessengerStorageLocation
        }
    }
}
