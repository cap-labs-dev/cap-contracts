// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./DataTypes.sol";

/// @title Premainnet vault storage pointer
/// @author kexley, @capLabs
library PreMainnetVaultStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.PreMainnetVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PreMainnetVaultStorageLocation =
        0xa32052a65e980f128858ffb78b2c1d6bb1e7ecda0ba46f7b16ec146539e21e00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.PreMainnetVaultStorage storage $) {
        assembly {
            $.slot := PreMainnetVaultStorageLocation
        }
    }
}
