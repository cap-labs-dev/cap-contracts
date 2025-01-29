// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Network storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library NetworkStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Network")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NetworkStorageLocation = 0xec23e17a5ca56acc6967467b8c4a73cf6149bcd343f3f3cbe7c4e19c4d822b00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.NetworkStorage storage $) {
        assembly {
            $.slot := NetworkStorageLocation
        }
    }
}
