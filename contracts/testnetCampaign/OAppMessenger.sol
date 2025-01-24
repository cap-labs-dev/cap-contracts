// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./libraries/DataTypes.sol";
import { OAppMessengerStorage } from "./libraries/OAppMessengerStorage.sol";

import { OAppSenderUpgradeable, OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";

/// @title OAppMessenger
/// @notice Messenger logic for the LayerZero bridge
contract OAppMessenger is OAppSenderUpgradeable {
    using OptionsBuilder for bytes;

    /// @dev OAppCore sets the endpoint as an immutable variable
    /// @param _lzEndpoint Local layerzero endpoint
    constructor(address _lzEndpoint) OAppCoreUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param _owner Owner/delegate address
    /// @param _dstEid Destination lz EID
    /// @param _decimals Decimals of the asset
    function __OAppMessenger_init(address _owner, uint32 _dstEid, uint8 _decimals) internal onlyInitializing {
        __Ownable_init(_owner);
        __OAppSender_init(_owner);
        __OAppMessenger_init_unchained(_dstEid, _decimals);
    }

    /// @notice Initialize unchained
    /// @param _dstEid Destination lz EID
    /// @param _decimals Decimals of the asset
    function __OAppMessenger_init_unchained(uint32 _dstEid, uint8 _decimals) internal onlyInitializing {
        DataTypes.OAppMessengerStorage storage $ = OAppMessengerStorage.get();
        $.dstEid = _dstEid;
        $.decimals = _decimals;
        $.lzReceiveGas = 100_000;
    }

    /// @notice Quote the fee for depositing via the LayerZero bridge
    /// @param _amountLD Amount in local decimals
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    /// @return fee Fee for the LayerZero bridge
    function quote(uint256 _amountLD, address _destReceiver) external view returns (MessagingFee memory fee) {
        DataTypes.OAppMessengerStorage storage $ = OAppMessengerStorage.get();
        (bytes memory message, bytes memory options) = _buildMsgAndOptions($.lzReceiveGas, _amountLD, _destReceiver);
        fee = _quote($.dstEid, message, options, false);
    }

    /// @dev Message using layer zero
    /// @param _destReceiver Receiver of assets on destination chain
    /// @param _amountLD Amount of asset in local decimals
    function _sendMessage(address _destReceiver, uint256 _amountLD) internal {
        DataTypes.OAppMessengerStorage storage $ = OAppMessengerStorage.get();
        MessagingFee memory _fee = MessagingFee({ nativeFee: msg.value, lzTokenFee: 0 });
        (bytes memory message, bytes memory options) = _buildMsgAndOptions($.lzReceiveGas, _amountLD, _destReceiver);
        _lzSend($.dstEid, message, options, _fee, _destReceiver);
    }

    /// @dev Build the message and options for the LayerZero bridge
    /// @param _gas Gas fee
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
        DataTypes.OAppMessengerStorage storage $ = OAppMessengerStorage.get();
        return uint64(_amountLD / (10 ** ($.decimals - sharedDecimals())));
    }

    /// @notice Retrieves the shared decimals of the OFT.
    /// @return The shared decimals of the OFT.
    function sharedDecimals() public view virtual returns (uint8) {
        return 6;
    }
}
