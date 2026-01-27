// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1155Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { Access } from "../access/Access.sol";
import { ISoulboundERC1155Merkle } from "../interfaces/ISoulboundERC1155Merkle.sol";
import { SoulboundERC1155MerkleStorageUtils } from "../storage/SoulboundERC1155MerkleStorageUtils.sol";

/// @title SoulboundERC1155Merkle
/// @author kexley, Cap Labs
/// @notice Soulbound ERC1155 with Merkle proofs for minting
/// @dev Admin must set the Merkle root and unpause to enable public minting. Hashed user addresses are used as leaves in the Merkle tree.
/// Once an address owns a token, it is soulbound and cannot be transferred. Only one token per address can be minted.
contract SoulboundERC1155Merkle is
    ISoulboundERC1155Merkle,
    UUPSUpgradeable,
    ERC1155Upgradeable,
    PausableUpgradeable,
    Access,
    SoulboundERC1155MerkleStorageUtils
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function initialize(address _accessControl, string calldata _uri) external initializer {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);
        __ERC1155_init(_uri);
        __Pausable_init();
        __UUPSUpgradeable_init();
        _pause(); // pause public minting by default
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function mint(address _to, bytes32[] calldata _proofs) external whenNotPaused {
        if (balanceOf(_to, 0) > 0) revert AlreadyMinted();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(_to))));
        if (!MerkleProof.verify(_proofs, getSoulboundERC1155MerkleStorage().root, leaf)) revert InvalidProof();
        _mint(_to, 0, 1, "");
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function ownerMint(address[] calldata _to) external checkAccess(this.ownerMint.selector) {
        for (uint256 i = 0; i < _to.length; i++) {
            if (balanceOf(_to[i], 0) > 0) revert AlreadyMinted();
            _mint(_to[i], 0, 1, "");
        }
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function setRoot(bytes32 _root) external checkAccess(this.setRoot.selector) {
        getSoulboundERC1155MerkleStorage().root = _root;
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function setURI(string calldata _uri) external checkAccess(this.setURI.selector) {
        _setURI(_uri);
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function pause() external checkAccess(this.pause.selector) {
        _pause();
    }

    /// @inheritdoc ISoulboundERC1155Merkle
    function unpause() external checkAccess(this.unpause.selector) {
        _unpause();
    }

    /// @dev Override to prevent transfers after minting
    /// @param _from Sender address
    /// @param _to Receiver address
    /// @param _ids Token IDs to transfer
    /// @param _values Amounts of tokens to transfer
    function _update(address _from, address _to, uint256[] memory _ids, uint256[] memory _values) internal override {
        if (_from != address(0)) revert Soulbound(); // only minting is allowed
        super._update(_from, _to, _ids, _values);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
