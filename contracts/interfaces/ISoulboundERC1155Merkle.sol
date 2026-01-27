// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISoulboundERC1155Merkle
/// @author kexley, Cap Labs
/// @notice Interface for Soulbound ERC1155 with Merkle proofs for minting
interface ISoulboundERC1155Merkle {
    /// @custom:storage-location erc7201:cap.storage.SoulboundERC1155Merkle
    /// @dev SoulboundERC1155Merkle storage
    /// @param root Merkle root
    struct SoulboundERC1155MerkleStorage {
        bytes32 root;
    }

    /// @dev Address already owns a token
    error AlreadyMinted();

    /// @dev Invalid Merkle proof
    error InvalidProof();

    /// @dev Token is soulbound
    error Soulbound();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Initialize the SoulboundERC1155Merkle token
    /// @dev Minting using Merkle proofs is paused by default
    /// @param _accessControl Access control address
    /// @param _uri URI for token metadata
    function initialize(address _accessControl, string memory _uri) external;

    /// @notice Mint a token to an address using Merkle proofs
    /// @dev Anyone can mint a token to an approved address using Merkle proofs on behalf of that address
    /// @param _to Address to mint the token to
    /// @param _proofs Merkle proofs for the address
    function mint(address _to, bytes32[] memory _proofs) external;

    /// @notice Mint a token to multiple addresses using owner privileges without Merkle proofs
    /// @param _to Addresses to mint the token to
    function ownerMint(address[] calldata _to) external;

    /// @notice Set the Merkle root
    /// @param _root Merkle root
    function setRoot(bytes32 _root) external;

    /// @notice Set the URI for token metadata
    /// @param _uri Base URI
    function setURI(string memory _uri) external;

    /// @notice Pause minting
    function pause() external;

    /// @notice Unpause minting
    function unpause() external;
}
