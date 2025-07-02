// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";

/// @title Fee Receiver Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for fee receiver
abstract contract FeeReceiverStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.FeeReceiver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FeeReceiverStorageLocation =
        0x22a89b069b09957a754cd7ed12b4d4d4fefa3dc957ead0f6120654eb51bf3900;

    /// @dev Get fee receiver storage
    /// @return $ Storage pointer
    function getFeeReceiverStorage() internal pure returns (IFeeReceiver.FeeReceiverStorage storage $) {
        assembly {
            $.slot := FeeReceiverStorageLocation
        }
    }
}
