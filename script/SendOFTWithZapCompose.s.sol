// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IBeefyZapRouter } from "../contracts/interfaces/IBeefyZapRouter.sol";
import { OFTZapMessage } from "../contracts/interfaces/IZapOFTComposer.sol";
import { OFTZapMessage } from "../contracts/interfaces/IZapOFTComposer.sol";
import { LzUtils } from "./util/LzUtils.sol";
import { WalletUtils } from "./util/WalletUtils.sol";
import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTReceipt, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console } from "forge-std/Script.sol";

/**
 * Send an OFT token to a target chain and compose a Zap message to zap the token out of the vault
 */
contract SendOFTWithZapCompose is Script, WalletUtils, LzUtils {
    using OptionsBuilder for bytes;

    function run() public {
        // Fetching environment variables
        address srcOftAddress = vm.envAddress("SRC_OFT_ADDRESS");
        uint256 srcAmount = vm.envUint("SRC_AMOUNT");
        uint256 dstChainId = vm.envUint("DST_CHAIN_ID");
        address dstComposerAddress = vm.envAddress("DST_COMPOSER_ADDRESS");
        address dstZapRouter = vm.envAddress("DST_ZAP_ROUTER");
        address dstStakedCapToken = vm.envAddress("DST_STAKED_CAP_TOKEN");
        address dstCapToken = vm.envAddress("DST_CAP_TOKEN");
        LzConfig memory toConfig = getLzConfig(vm, dstChainId);

        vm.startBroadcast();

        address toAddress = getWalletAddress();
        console.log("Sending from address: ", toAddress);
        console.log("From oft balance: ", IERC20(srcOftAddress).balanceOf(toAddress));
        console.log("From native balance: ", address(toAddress).balance);
        console.log("Sending to address: ", toAddress);

        IOFT sourceOFT = IOFT(srcOftAddress);
        IERC20 token = IERC20(sourceOFT.token());

        // ------------------------------- build OFTZapMessage

        IBeefyZapRouter.Input[] memory inputs = new IBeefyZapRouter.Input[](1);
        inputs[0] = IBeefyZapRouter.Input({ token: address(dstStakedCapToken), amount: srcAmount });

        IBeefyZapRouter.Output[] memory outputs = new IBeefyZapRouter.Output[](1);
        outputs[0] = IBeefyZapRouter.Output({ token: address(dstCapToken), minOutputAmount: srcAmount * 999 / 1000 });

        IBeefyZapRouter.Relay memory noRelay = IBeefyZapRouter.Relay({ target: address(0), value: 0, data: "" });

        IBeefyZapRouter.Order memory order = IBeefyZapRouter.Order({
            inputs: inputs,
            outputs: outputs,
            relay: noRelay,
            user: dstComposerAddress,
            recipient: toAddress
        });

        IBeefyZapRouter.StepToken[] memory tokens = new IBeefyZapRouter.StepToken[](1);
        tokens[0] = IBeefyZapRouter.StepToken({ token: address(dstStakedCapToken), index: 4 /* selector size */ });
        IBeefyZapRouter.Step[] memory route = new IBeefyZapRouter.Step[](1);
        route[0] = IBeefyZapRouter.Step({
            target: dstStakedCapToken,
            value: 0,
            data: abi.encodeWithSelector(IERC4626.withdraw.selector, srcAmount, dstZapRouter, dstZapRouter),
            tokens: new IBeefyZapRouter.StepToken[](0)
        });

        OFTZapMessage memory zapMessage = OFTZapMessage({ value: 0, order: order, route: route });
        uint256 zapGasEstimate = 7e15;

        bytes memory _extraOptions =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0).addExecutorLzComposeOption(0, 65000, 0);
        SendParam memory sendParam = SendParam(
            toConfig.eid,
            addressToBytes32(dstComposerAddress),
            srcAmount,
            srcAmount * 9 / 10,
            _extraOptions,
            abi.encode(zapMessage),
            ""
        );

        // ------------------------------- quoteSend

        MessagingFee memory fee = sourceOFT.quoteSend(sendParam, false);
        fee.nativeFee += zapGasEstimate;

        console.log("Fee amount: ", fee.nativeFee);

        token.approve(address(sourceOFT), srcAmount);
        sourceOFT.send{ value: fee.nativeFee }(sendParam, fee, getWalletAddress());

        // Stop broadcasting
        vm.stopBroadcast();
    }
}
