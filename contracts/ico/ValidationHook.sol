// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { PredicateClient } from "@predicate/mixins/PredicateClient.sol";

import { Access } from "../access/Access.sol";
import { IContinuousClearingAuction } from "../interfaces/IContinuousClearingAuction.sol";
import {
    IERC165,
    IGatedERC1155ValidationHook,
    IPredicateClient,
    IValidationHook
} from "../interfaces/IValidationHook.sol";
import { ValidationHookStorageUtils } from "../storage/ValidationHookStorageUtils.sol";

/// @title ValidationHook
/// @author kexley, Cap Labs
/// @notice Validation hook using a soulbound ERC1155 token, a time gate and attestations from Predicate.
/// @dev This hook validates that the sender is the owner of a specific ERC1155 token or the time gate has passed.
/// Attestations are used to validate that the sender is KYC/KYB compliant. The auction address is set after
/// initialization since this contract address is used in the auction constructor.
contract ValidationHook is IValidationHook, UUPSUpgradeable, PredicateClient, Access, ValidationHookStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IValidationHook
    function initialize(
        address _accessControl,
        address _erc1155,
        uint256 _tokenId,
        uint256 _expirationBlock,
        address _registry,
        string memory _policyID
    ) external initializer {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);

        if (_erc1155 == address(0)) revert ZeroAddressNotValid();
        ValidationHookStorage storage $ = getValidationHookStorage();
        $.erc1155 = _erc1155;
        $.tokenId = _tokenId;

        if (_expirationBlock < block.number) revert InvalidExpirationBlock();
        $.expirationBlock = _expirationBlock;

        _initPredicateClient(_registry, _policyID);

        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IValidationHook
    function validate(uint256, uint128, address _owner, address _sender, bytes calldata _hookData) external {
        ValidationHookStorage storage $ = getValidationHookStorage();

        // attestations can be wasted by third parties if not routed through the auction
        if (msg.sender != $.auction) revert CallerMustBeAuction();

        // the sender must be the owner of the bid
        if (_sender != _owner) revert SenderMustBeOwner();

        // if expiration block is not passed, the sender must be the owner of the ERC1155 token
        if (block.number < $.expirationBlock) {
            if (IERC1155($.erc1155).balanceOf(_sender, $.tokenId) == 0) revert NotOwnerOfERC1155Token();
        }

        // attestation is decoded from the hook data
        Attestation memory attestation = abi.decode(_hookData, (Attestation));

        // empty encodedSigAndArgs means only the _sender address is validated for compliance
        if (!_authorizeTransaction(attestation, hex"", _sender, 0)) revert InvalidAttestation();

        emit AttestationValidated(_sender, attestation.uuid);
    }

    /// @inheritdoc IValidationHook
    function setAuction(address _auction) external checkAccess(this.setAuction.selector) {
        ValidationHookStorage storage $ = getValidationHookStorage();
        if (_auction == address(0)) revert ZeroAddressNotValid();
        if (
            IContinuousClearingAuction(_auction).startBlock() > $.expirationBlock
                || IContinuousClearingAuction(_auction).endBlock() < $.expirationBlock
        ) revert InvalidAuctionBlock();

        $.auction = _auction;
        emit SetAuction(_auction);
    }

    /// @inheritdoc IValidationHook
    function setErc1155(address _erc1155) external checkAccess(this.setErc1155.selector) {
        if (_erc1155 == address(0)) revert ZeroAddressNotValid();
        getValidationHookStorage().erc1155 = _erc1155;
        emit SetErc1155(_erc1155);
    }

    /// @inheritdoc IValidationHook
    function setTokenId(uint256 _tokenId) external checkAccess(this.setTokenId.selector) {
        getValidationHookStorage().tokenId = _tokenId;
        emit SetTokenId(_tokenId);
    }

    /// @inheritdoc IValidationHook
    function setExpirationBlock(uint256 _expirationBlock) external checkAccess(this.setExpirationBlock.selector) {
        getValidationHookStorage().expirationBlock = _expirationBlock;
        emit SetExpirationBlock(_expirationBlock);
    }

    /// @inheritdoc IPredicateClient
    function setRegistry(address _registry) external checkAccess(this.setRegistry.selector) {
        _setRegistry(_registry);
    }

    /// @inheritdoc IPredicateClient
    function setPolicyID(string memory _policyID) external checkAccess(this.setPolicyID.selector) {
        _setPolicyID(_policyID);
    }

    /// @inheritdoc IValidationHook
    function auction() external view returns (address) {
        return getValidationHookStorage().auction;
    }

    /// @inheritdoc IGatedERC1155ValidationHook
    function erc1155() external view returns (IERC1155) {
        return IERC1155(getValidationHookStorage().erc1155);
    }

    /// @inheritdoc IGatedERC1155ValidationHook
    function tokenId() external view returns (uint256) {
        return getValidationHookStorage().tokenId;
    }

    /// @inheritdoc IGatedERC1155ValidationHook
    function expirationBlock() external view returns (uint256) {
        return getValidationHookStorage().expirationBlock;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IValidationHook).interfaceId || interfaceId == type(IPredicateClient).interfaceId
            || interfaceId == type(IGatedERC1155ValidationHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
