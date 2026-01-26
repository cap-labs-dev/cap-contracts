// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { Access } from "../access/Access.sol";
import { IValidationHook } from "../interfaces/IValidationHook.sol";
import { ValidationHookStorageUtils } from "../storage/ValidationHookStorageUtils.sol";

/// @title ValidationHook
/// @author kexley, Cap Labs
/// @notice Validation hook using a soulbound ERC721 token and a time gate
/// @dev This hook validates that the sender is the owner of a specific ERC721 token or the time gate has passed
contract ValidationHook is IValidationHook, UUPSUpgradeable, Access, ValidationHookStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IValidationHook
    function initialize(address _accessControl, address _token, uint256 _gate) external initializer {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);

        if (_token == address(0)) revert ZeroAddressNotValid();
        ValidationHookStorage storage $ = getValidationHookStorage();
        $.token = _token;

        if (_gate < block.timestamp) revert InvalidGate();
        $.gate = _gate;

        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IValidationHook
    function validate(uint256, uint128, address owner, address sender, bytes calldata) external view {
        if (sender != owner) revert SenderMustBeOwner();

        ValidationHookStorage storage $ = getValidationHookStorage();
        if (block.timestamp < $.gate) {
            if (IERC721($.token).balanceOf(owner) == 0) revert NotOwnerOfERC721Token();
        }
    }

    /// @inheritdoc IValidationHook
    function setToken(address _token) external checkAccess(this.setToken.selector) {
        if (_token == address(0)) revert ZeroAddressNotValid();
        getValidationHookStorage().token = _token;
    }

    /// @inheritdoc IValidationHook
    function setGate(uint256 _gate) external checkAccess(this.setGate.selector) {
        getValidationHookStorage().gate = _gate;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
