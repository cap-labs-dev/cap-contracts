// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";
import { OFTZapMessage } from "../interfaces/IZapOFTComposer.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ZapOFTComposer
/// @author @capLabs
/// @notice Compose an OFT with Zap capabilities
/// @dev This contract is used to compose an OFT message with Zap capabilities.
///      It handles ERC20 approvals, zap execution, and refunds the remaining tokens to the zap recipient.
contract ZapOFTComposer is ILayerZeroComposer {
    using SafeERC20 for IERC20;

    /// @notice Store LayerZero addresses.
    address public immutable endpoint;
    address public immutable oApp;
    address public immutable zapRouter;
    address public immutable zapTokenManager;

    /// @notice Constructs the contract.
    /// @dev Initializes the contract.
    /// @param _oApp The address of the OApp that is sending the composed message.
    /// @param _zapRouter The address of the ZapRouter to use for Zap capabilities.
    constructor(address _endpoint, address _oApp, address _zapRouter, address _zapTokenManager) {
        endpoint = _endpoint;
        oApp = _oApp;
        zapRouter = _zapRouter;
        zapTokenManager = _zapTokenManager;
    }

    /// @notice Handles incoming composed messages from LayerZero and send the payload to the ZapRouter.
    /// @dev This compose function does not try to decode the message payload at all and just passes it to the ZapRouter.
    /// @param _oApp The address of the originating OApp.
    /// @param /*_guid*/ The globally unique identifier of the message.
    /// @param _message The encoded message content.
    function lzCompose(address _oApp, bytes32, /*_guid*/ bytes calldata _message, address, bytes calldata)
        external
        payable
        override
    {
        // Perform checks to make sure composed message comes from correct OApp.
        require(_oApp == oApp, "!oApp");
        require(msg.sender == endpoint, "!endpoint");

        // Decode the payload to get the message
        (OFTZapMessage memory zapMessage) = abi.decode(_message, (OFTZapMessage));

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
        IBeefyZapRouter(zapRouter).executeOrder{ value: zapMessage.value }(zapMessage.order, zapMessage.route);

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

        // send the remaining gas to the recipient
        if (msg.value > 0) {
            payable(fallbackRecipient).transfer(msg.value);
        }
    }
}
