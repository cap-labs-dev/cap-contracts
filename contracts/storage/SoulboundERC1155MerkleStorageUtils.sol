// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISoulboundERC1155Merkle } from "../interfaces/ISoulboundERC1155Merkle.sol";

/// @title SoulboundERC1155Merkle Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for SoulboundERC1155Merkle
abstract contract SoulboundERC1155MerkleStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.SoulboundERC1155Merkle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SoulboundERC1155MerkleStorageLocation =
        0x6d5a367baf12d23a28fe5a1303a7e187165117fd327ccfa867169347edcde600;

    /// @dev Get SoulboundERC1155Merkle storage
    /// @return $ Storage pointer
    function getSoulboundERC1155MerkleStorage()
        internal
        pure
        returns (ISoulboundERC1155Merkle.SoulboundERC1155MerkleStorage storage $)
    {
        assembly {
            $.slot := SoulboundERC1155MerkleStorageLocation
        }
    }
}
