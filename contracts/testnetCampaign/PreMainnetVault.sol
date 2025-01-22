// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PreMainnetVaultStorage, PreMainnetVaultStorageLib } from "./PreMainnetVaultStorage.sol";

import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import { OAppSenderUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PreMainnetVault
/// @notice Vault for pre-mainnet campaign
/// @dev Campaign has a maximum timestamp after which transfers are enabled

contract PreMainnetVault is UUPSUpgradeable, ERC20PermitUpgradeable, OwnableUpgradeable, OAppSenderUpgradeable {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    /// @dev Zero amounts are not allowed for minting
    error ZeroAmount();

    /// @dev Transfers not yet enabled
    error TransferNotEnabled();

    /// @dev Deposit underlying asset
    event Deposit(address indexed user, uint256 amount);

    /// @dev Withdraw underlying asset
    event Withdraw(address indexed user, uint256 amount);

    /// @dev Transfers enabled
    event TransferEnabled();

    constructor(address _lzEndpoint) OAppCoreUpgradeable(_lzEndpoint) { }

    /// @notice Initialize
    /// @param _dstEid Destination lz EID
    /// @param _asset Underlying asset
    /// @param _maxCampaignLength Max campaign length in seconds
    function initialize(uint32 _dstEid, address _asset, uint256 _maxCampaignLength) external initializer {
        string memory _name = string.concat(string.concat("Pre-Mainnet Vault ", IERC20Metadata(_asset).name()));
        string memory _symbol = string.concat("pm", IERC20Metadata(_asset).symbol());
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Ownable_init(msg.sender);
        __OAppSender_init(msg.sender);

        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        $.dstEid = _dstEid;
        $.asset = IERC20(_asset);
        $.maxCampaignEnd = block.timestamp + _maxCampaignLength;
        $.decimals = IERC20Metadata(_asset).decimals();
        $.lzReceiveGas = 100_000;
    }

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param _amount Amount of underlying asset to deposit
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    function deposit(uint256 _amount, address _destReceiver) external payable {
        if (_amount == 0) revert ZeroAmount();

        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        $.asset.safeTransferFrom(msg.sender, address(this), _amount);

        _mint(msg.sender, _amount);

        // bridge logic
        MessagingFee memory _fee = MessagingFee({ nativeFee: msg.value, lzTokenFee: 0 });
        (bytes memory message, bytes memory options) = _buildMsgAndOptions($.lzReceiveGas, _amount, _destReceiver);
        _lzSend($.dstEid, message, options, _fee, _destReceiver);
        OFTReceipt(_amount, _amount);

        emit Deposit(msg.sender, _amount);
    }

    /// @dev Quote the deposit amount for the LayerZero bridge
    /// @param _amountLD Amount in local decimals
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    /// @return fee Fee for the LayerZero bridge
    function quoteDeposit(uint256 _amountLD, address _destReceiver) external view returns (MessagingFee memory fee) {
        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        (bytes memory message, bytes memory options) = _buildMsgAndOptions($.lzReceiveGas, _amountLD, _destReceiver);
        fee = _quote($.dstEid, message, options, false);
    }

    /// @dev Build the message and options for the LayerZero bridge
    /// @param _amountLD Amount in local decimals
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    /// @return message Message for the LayerZero bridge
    /// @return options Options for the LayerZero bridge
    function _buildMsgAndOptions(uint128 _gas, uint256 _amountLD, address _destReceiver)
        internal
        view
        returns (bytes memory message, bytes memory options)
    {
        (message,) = OFTMsgCodec.encode(OFTMsgCodec.addressToBytes32(_destReceiver), _toSD(_amountLD), "");
        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_gas, 0);
    }

    /// @dev Convert amount in shared decimals to amount in local decimals
    /// @param _amountLD Amount in local decimals
    /// @return amountSD Amount in shared decimals
    function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
        return uint64(_amountLD / (10 ** (decimals() - sharedDecimals())));
    }

    /**
     * @dev Retrieves the shared decimals of the OFT.
     * @return The shared decimals of the OFT.
     *
     * @dev Sets an implicit cap on the amount of tokens, over uint64.max() will need some sort of outbound cap / totalSupply cap
     * Lowest common decimal denominator between chains.
     * Defaults to 6 decimal places to provide up to 18,446,744,073,709.551615 units (max uint64).
     * For tokens exceeding this totalSupply(), they will need to override the sharedDecimals function with something smaller.
     * ie. 4 sharedDecimals would be 1,844,674,407,370,955.1615
     */
    function sharedDecimals() public view virtual returns (uint8) {
        return 6;
    }

    /// @notice Withdraw underlying asset after campaign ends
    /// @param _amount Amount of underlying asset to withdraw
    /// @param _receiver Receiver of the withdrawn underlying assets
    function withdraw(uint256 _amount, address _receiver) external {
        _burn(msg.sender, _amount);

        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        $.asset.safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Override decimals to return decimals of underlying asset
    /// @return decimals Asset decimals
    function decimals() public view override returns (uint8) {
        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        return $.decimals;
    }

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() public view returns (bool enabled) {
        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        enabled = $.allowTransferBeforeCampaignEnd || block.timestamp > $.maxCampaignEnd;
    }

    /// @notice Enable transfers after campaign ends
    function enableTransfer() external onlyOwner {
        PreMainnetVaultStorage storage $ = PreMainnetVaultStorageLib.get();
        $.allowTransferBeforeCampaignEnd = true;
        emit TransferEnabled();
    }

    /// @dev Override _update to disable transfer before campaign ends
    /// @param _from From address
    /// @param _to To address
    /// @param _value Amount to transfer
    function _update(address _from, address _to, uint256 _value) internal override {
        if (!transferEnabled() && _from != address(0)) revert TransferNotEnabled();
        super._update(_from, _to, _value);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal override {
        super._transferOwnership(newOwner);
        ILayerZeroEndpointV2(endpoint).setDelegate(newOwner);
    }

    /// @dev Only owner can upgrade
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
