// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title ISoulboundERC1155Merkle
/// @author kexley, Cap Labs
/// @notice Interface for Soulbound ERC1155 with Merkle proofs for minting
interface ISoulboundERC1155Merkle is IERC1155 {
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

    /// @dev Emitted when the Merkle root is set
    event SetRoot(bytes32 root);

    /// @dev Emitted when the URI is set
    event SetURI(string uri);

    /// @notice Initialize the SoulboundERC1155Merkle token
    /// @dev Minting using Merkle proofs is paused by default
    /// @param _accessControl Access control address
    /// @param _uri URI for token metadata
    function initialize(address _accessControl, string calldata _uri) external;

    /// @notice Mint a token to an address using Merkle proofs
    /// @dev Anyone can mint a token to an approved address using Merkle proofs on behalf of that address
    /// @param _to Address to mint the token to
    /// @param _proofs Merkle proofs for the address
    function mint(address _to, bytes32[] calldata _proofs) external;

    /// @notice Mint a token to multiple addresses using owner privileges without Merkle proofs
    /// @param _to Addresses to mint the token to
    function ownerMint(address[] calldata _to) external;

    /// @notice Set the Merkle root
    /// @param _root Merkle root
    function setRoot(bytes32 _root) external;

    /// @notice Set the URI for token metadata
    /// @param _uri Base URI
    function setURI(string calldata _uri) external;

    /// @notice Pause minting
    function pause() external;

    /// @notice Unpause minting
    function unpause() external;

    /// @notice Get the Merkle root
    /// @return root Merkle root
    function root() external view returns (bytes32);
}
