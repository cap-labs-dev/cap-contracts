// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { Access } from "../access/Access.sol";
import { ISoulboundERC721Merkle } from "../interfaces/ISoulboundERC721Merkle.sol";
import { SoulboundERC721MerkleStorageUtils } from "../storage/SoulboundERC721MerkleStorageUtils.sol";

/// @title SoulboundERC721Merkle
/// @author kexley, Cap Labs
/// @notice Soulbound ERC721 with Merkle proofs for minting
/// @dev Admin must set the Merkle root and unpause to enable public minting. Hashed user addresses are used as leaves in the Merkle tree.
/// Once an address owns a token, it is soulbound and cannot be transferred. Only one token per address can be minted.
contract SoulboundERC721Merkle is
    ISoulboundERC721Merkle,
    UUPSUpgradeable,
    ERC721EnumerableUpgradeable,
    PausableUpgradeable,
    Access,
    SoulboundERC721MerkleStorageUtils
{
    /// @inheritdoc ISoulboundERC721Merkle
    function initialize(address _accessControl, string memory _name, string memory _symbol) external initializer {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);
        __ERC721_init(_name, _symbol);
        __Pausable_init();
        __UUPSUpgradeable_init();
        _pause(); // pause public minting by default
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function mint(address _to, bytes32[] memory _proofs) external whenNotPaused {
        if (balanceOf(_to) > 0) revert AlreadyMinted();
        bytes32 leaf = keccak256(abi.encode(_to));
        MerkleProof.verify(_proofs, getSoulboundERC721MerkleStorage().root, leaf);
        _safeMint(_to, totalSupply());
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function ownerMint(address[] calldata _to) external checkAccess(this.ownerMint.selector) {
        for (uint256 i = 0; i < _to.length; i++) {
            if (balanceOf(_to[i]) > 0) revert AlreadyMinted();
            _safeMint(_to[i], totalSupply());
        }
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function setRoot(bytes32 _root) external checkAccess(this.setRoot.selector) {
        getSoulboundERC721MerkleStorage().root = _root;
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function setBaseURI(string memory _baseURI) external checkAccess(this.setBaseURI.selector) {
        getSoulboundERC721MerkleStorage().baseURI = _baseURI;
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function pause() external checkAccess(this.pause.selector) {
        _pause();
    }

    /// @inheritdoc ISoulboundERC721Merkle
    function unpause() external checkAccess(this.unpause.selector) {
        _unpause();
    }

    /// @dev Override the _update function to prevent transfers after minting
    /// @param _to Address to transfer the token to
    /// @param _tokenId Token ID to transfer
    /// @param _auth Address that is authorized to transfer the token on behalf of the owner
    function _update(address _to, uint256 _tokenId, address _auth) internal override returns (address) {
        address from = _ownerOf(_tokenId);
        if (from != address(0)) revert Soulbound(); // only minting is allowed
        return super._update(_to, _tokenId, _auth);
    }

    /// @dev Override the empty _baseURI function to return the base URI set by the admin
    /// @return . Base URI address
    function _baseURI() internal view override returns (string memory) {
        return getSoulboundERC721MerkleStorage().baseURI;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
