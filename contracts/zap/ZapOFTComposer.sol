// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";
import { SafeOFTLzComposer } from "./SafeOFTLzComposer.sol";
import { ZapOFTComposerMessageCodec } from "./ZapOFTComposerMessageCodec.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ZapOFTComposer
/// @author @capLabs
/// @notice Compose an OFT with Zap capabilities
/// @dev This contract is used to compose an OFT message with Zap capabilities.
///      It handles ERC20 approvals, zap execution, and refunds the remaining tokens to the zap recipient.
///      Expects the funds to be sent to the ZapOFTComposer contract before the message is composed.
contract ZapOFTComposer is SafeOFTLzComposer {
    using SafeERC20 for IERC20;

    /// @notice Store ZapRouter addresses.
    address public immutable zapRouter;
    address public immutable zapTokenManager;

    /// @notice Constructs the contract.
    /// @dev Initializes the contract.
    /// @param _oApp The address of the OApp that is sending the composed message.
    /// @param _zapRouter The address of the ZapRouter to use for Zap capabilities.
    constructor(address _endpoint, address _oApp, address _zapRouter, address _zapTokenManager)
        SafeOFTLzComposer(_oApp, _endpoint)
    {
        zapRouter = _zapRouter;
        zapTokenManager = _zapTokenManager;
    }

    /// @notice Handles incoming composed messages from LayerZero OFTs and executes the zap order it represents.
    /// @dev This compose function does not try to decode the message payload at all and just passes it to the ZapRouter.
    /// @param /*_oApp*/ The address of the originating OApp.
    /// @param /*_guid*/ The globally unique identifier of the message.
    /// @param _message The encoded message content.
    function _lzCompose(address, /*_oApp*/ bytes32, /*_guid*/ bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        // Decode the payload to get the message
        ZapOFTComposerMessageCodec.ZapMessage memory zapMessage = ZapOFTComposerMessageCodec.decodeCompose(_message);

        // approve all inputs to the zapTokenManager
        IBeefyZapRouter.Input[] memory inputs = zapMessage.order.inputs;
        uint256 inputLength = inputs.length;
        for (uint256 i = 0; i < inputLength; i++) {
            IBeefyZapRouter.Input memory input = inputs[i];
            uint256 balance = IERC20(input.token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(input.token).approve(zapTokenManager, balance);
            }
        }

        // execute a zap order
        IBeefyZapRouter(zapRouter).executeOrder(zapMessage.order, zapMessage.route);

        // send the remaining tokens to the recipient
        address fallbackRecipient = zapMessage.order.recipient;
        for (uint256 i = 0; i < inputLength; i++) {
            IBeefyZapRouter.Input memory input = inputs[i];
            uint256 balance = IERC20(input.token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(input.token).safeTransfer(fallbackRecipient, balance);
            }
        }

        // send the remaining output tokens to the recipient
        IBeefyZapRouter.Output[] memory outputs = zapMessage.order.outputs;
        uint256 outputLength = outputs.length;
        for (uint256 i = 0; i < outputLength; i++) {
            IBeefyZapRouter.Output memory output = outputs[i];
            uint256 balance = IERC20(output.token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(output.token).safeTransfer(fallbackRecipient, balance);
            }
        }
    }
}
