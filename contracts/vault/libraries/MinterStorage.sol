// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Minter storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library MinterStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Minter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MinterStorageLocation = 0x3b40995b576f8dd0a8521bba471c5346e53f6a25529b0903b82331eb1a2afe00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.MinterStorage storage $) {
        assembly {
            $.slot := MinterStorageLocation
        }
    }
}
