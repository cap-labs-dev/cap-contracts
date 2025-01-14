// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CapToken } from "../contracts/token/CapToken.sol";
import { OFTLockbox } from "../contracts/token/OFTLockbox.sol";
import { StakedCap } from "../contracts/token/StakedCap.sol";
import { LzUtils } from "./util/LzUtils.sol";
import { WalletUtils } from "./util/WalletUtils.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/interfaces/IMessageLibManager.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the lockboxes for the cap token and staked cap token
 */
contract ConfigureOApp is Script, WalletUtils, LzUtils {
    function run() public {
        address oapp = vm.envAddress("OAPP");
        uint256 targetId = vm.envUint("TARGET_CHAIN_ID");

        LzConfig memory config = getLzConfig(vm, block.chainid);
        ILayerZeroEndpointV2 lzEndpoint = config.endpointV2;
        uint32 targetEid = getLzConfig(vm, targetId).eid;

        vm.startBroadcast();

        address owner = getWalletAddress();
        console.log("owner", owner);

        uint256 gracePeriod = 1;
        console.log("gracePeriod", gracePeriod);

        address sendLibrary = config.sendUln302;
        console.log("sendLibrary", sendLibrary);
        address receiveLibrary = config.receiveUln302;
        console.log("receiveLibrary", receiveLibrary);

        SetConfigParam[] memory sendConfig = new SetConfigParam[](0);
        SetConfigParam[] memory receiveConfig = new SetConfigParam[](0);

        lzEndpoint.setSendLibrary(oapp, targetEid, sendLibrary);
        lzEndpoint.setReceiveLibrary(oapp, targetEid, receiveLibrary, gracePeriod);
        lzEndpoint.setReceiveLibraryTimeout(oapp, targetEid, receiveLibrary, gracePeriod);
        lzEndpoint.setConfig(oapp, sendLibrary, sendConfig);
        lzEndpoint.setConfig(oapp, receiveLibrary, receiveConfig);
        lzEndpoint.setDelegate(owner);

        vm.stopBroadcast();
    }
}
