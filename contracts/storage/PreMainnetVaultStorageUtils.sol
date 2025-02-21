// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IPreMainnetVault } from "../interfaces/IPreMainnetVault.sol";

/// @title PreMainnetVaultStorageUtils
/// @author @capLabs
/// @notice Storage utilities for PreMainnetVault contract
contract PreMainnetVaultStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.PreMainnetVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant PreMainnetVaultStorageLocation = 0xa32052a65e980f128858ffb78b2c1d6bb1e7ecda0ba46f7b16ec146539e21e00;

    /// @notice Get vault storage
    /// @return $ Storage pointer
    function getPreMainnetVaultStorage() internal pure returns (IPreMainnetVault.PreMainnetVaultStorage storage $) {
        assembly {
            $.slot := PreMainnetVaultStorageLocation
        }
    }
}
