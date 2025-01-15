// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/// @notice A library for encoding and decoding zap messages for the OFT composer.
/// @author @caplabs
library ZapOFTComposerMessageCodec {
    uint8 private constant FALLBACK_RECIPIENT_OFFSET = 0;

    struct ZapMessage {
        /// @notice Funds will be sent back to this address if the zap fails or the message is not formed correctly.
        address fallbackRecipient;
        /// @notice The zap order to execute.
        IBeefyZapRouter.Order order;
        /// @notice The zap route to execute.
        IBeefyZapRouter.Step[] route;
    }

    /// @notice Decodes the fallback recipient from the OFT zap message
    /// @dev This function does not attempt to decode the whole message, only the fallback recipient
    ///      this is on purpose as this is method is used to send OFT tokens back if the zap fails
    ///      or if the composed message is not formed correctly.
    /// @param message The encoded message content.
    /// @return _fallbackRecipient The fallback recipient address.
    function fallbackRecipient(bytes calldata message) internal pure returns (address _fallbackRecipient) {
        _fallbackRecipient = address(bytes20(message[FALLBACK_RECIPIENT_OFFSET:20]));
    }

    /// @notice Encodes the zap message for sending via OFT
    /// @param message The zap message to encode.
    /// @return The encoded zap message.
    function encodeForSend(ZapMessage memory message) internal pure returns (bytes memory) {
        return abi.encode(message);
    }

    /// @notice Decodes the zap message from the OFT compose message
    /// @param composeMessage The OFT compose message to decode.
    /// @return _message The decoded zap message.
    function decodeCompose(bytes calldata composeMessage) internal pure returns (ZapMessage memory _message) {
        bytes memory payload = OFTComposeMsgCodec.composeMsg(composeMessage);
        return abi.decode(payload, (ZapMessage));
    }

    /// @notice Decodes the amount of OFT tokens in local decimals from the OFT compose message
    /// @param composeMessage The OFT compose message to decode.
    /// @return The amount of OFT tokens in local decimals.
    function amountLD(bytes calldata composeMessage) internal pure returns (uint256) {
        return OFTComposeMsgCodec.amountLD(composeMessage);
    }
}
