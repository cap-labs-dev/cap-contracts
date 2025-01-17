// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Lender storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library LenderStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Lender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LenderStorageLocation = 0xd6af1ec8a1789f5ada2b972bd1569f7c83af2e268be17cd65efe8474ebf08800;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.LenderStorage storage $) {
        assembly {
            $.slot := LenderStorageLocation
        }
    }
}
