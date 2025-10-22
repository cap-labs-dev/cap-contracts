// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IWrapper } from "../interfaces/IWrapper.sol";
import { WrapperStorageUtils } from "../storage/WrapperStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20WrapperUpgradeable,
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Wrapper
/// @author kexley, Cap Labs
/// @notice Token wrapper where any donations are skimmed to the donation receiver
contract Wrapper is IWrapper, IERC721Receiver, UUPSUpgradeable, ERC20WrapperUpgradeable, Access, WrapperStorageUtils {
    using Strings for string;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IWrapper
    function initialize(address _accessControl, address _donationReceiver, address _asset) external initializer {
        if (_accessControl == address(0) || _donationReceiver == address(0) || _asset == address(0)) {
            revert ZeroAddress();
        }

        __Access_init(_accessControl);
        __ERC20_init(
            string.concat("Wrapped ", IERC20Metadata(_asset).name()),
            string.concat("w", IERC20Metadata(_asset).symbol())
        );
        __ERC20Wrapper_init(IERC20(_asset));
        __UUPSUpgradeable_init();

        getWrapperStorage().donationReceiver = _donationReceiver;
    }

    /// @inheritdoc IWrapper
    function setDonationReceiver(address _donationReceiver) external checkAccess(this.setDonationReceiver.selector) {
        if (_donationReceiver == address(0)) revert ZeroAddress();
        getWrapperStorage().donationReceiver = _donationReceiver;
        emit SetDonationReceiver(_donationReceiver);
    }

    /// @inheritdoc IWrapper
    function skim() external returns (uint256 amount) {
        address _donationReceiver = donationReceiver();
        amount = _recover(_donationReceiver);
        emit Skim(_donationReceiver, amount);
    }

    /// @inheritdoc IWrapper
    function donationReceiver() public view returns (address donationReceiverAddress) {
        donationReceiverAddress = getWrapperStorage().donationReceiver;
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IWrapper
    function skimmable() external view returns (uint256 amount) {
        uint256 _balance = underlying().balanceOf(address(this));
        uint256 _totalSupply = totalSupply();
        if (_balance > _totalSupply) amount = _balance - _totalSupply;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
