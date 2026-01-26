// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISoulboundERC721Merkle
/// @author kexley, Cap Labs
/// @notice Interface for Soulbound ERC721 with Merkle proofs for minting
interface ISoulboundERC721Merkle {
    /// @custom:storage-location erc7201:cap.storage.SoulboundERC721Merkle
    /// @dev SoulboundERC721Merkle storage
    /// @param root Merkle root
    /// @param baseURI Base URI
    struct SoulboundERC721MerkleStorage {
        bytes32 root;
        string baseURI;
    }

    /// @dev Address already owns a token
    error AlreadyMinted();

    /// @dev Invalid Merkle proof
    error InvalidProof();

    /// @dev Token is soulbound
    error Soulbound();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Initialize the SoulboundERC721Merkle token
    /// @dev Minting using Merkle proofs is paused by default
    /// @param _accessControl Access control address
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    function initialize(address _accessControl, string memory _name, string memory _symbol) external;

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

    /// @notice Set the base URI for token metadata
    /// @param _baseURI Base URI
    function setBaseURI(string memory _baseURI) external;

    /// @notice Pause minting
    function pause() external;

    /// @notice Unpause minting
    function unpause() external;
}
