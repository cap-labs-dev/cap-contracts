// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISoulboundERC721Merkle } from "../interfaces/ISoulboundERC721Merkle.sol";

/// @title SoulboundERC721Merkle Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for SoulboundERC721Merkle
abstract contract SoulboundERC721MerkleStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.SoulboundERC721Merkle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SoulboundERC721MerkleStorageLocation =
        0x97a2310d14bf455c1b044db05ac466986623b22a83f06520c8e2e54dc518e300;

    /// @dev Get SoulboundERC721Merkle storage
    /// @return $ Storage pointer
    function getSoulboundERC721MerkleStorage()
        internal
        pure
        returns (ISoulboundERC721Merkle.SoulboundERC721MerkleStorage storage $)
    {
        assembly {
            $.slot := SoulboundERC721MerkleStorageLocation
        }
    }
}
