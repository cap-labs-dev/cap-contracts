// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IRegistry } from "../interfaces/IRegistry.sol";

/// @title Registry Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Registry
abstract contract RegistryStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Registry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REGISTRY_STORAGE_LOCATION =
        0xa302af9fc7a4b22396106911579b0bc0b9d88a46cdfddd4b499f6c4a978bcd00;

    /// @dev Get Registry storage
    /// @return $ Storage pointer
    function getRegistryStorage() internal pure returns (IRegistry.Storage storage $) {
        assembly {
            $.slot := REGISTRY_STORAGE_LOCATION
        }
    }
}
