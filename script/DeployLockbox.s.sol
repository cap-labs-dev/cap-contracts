// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CapToken } from "../contracts/token/CapToken.sol";
import { OFTLockbox } from "../contracts/token/OFTLockbox.sol";
import { StakedCap } from "../contracts/token/StakedCap.sol";
import { LzUtils } from "./util/LzUtils.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/interfaces/ILayerZeroEndpointV2.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the lockboxes for the cap token and staked cap token
 *
 * Usage:
 *   SC_TOKEN=0x... forge script --chain sepolia --fork-url sepolia --account cap-dev --sender 0x... --verifier etherscan --verify script/DeployLockbox.s.sol:DeployLockbox
 */
contract DeployLockbox is Script, LzUtils {
    function run() public {
        ILayerZeroEndpointV2 lzEndpoint = getLzConfig(vm, block.chainid).endpointV2;
        StakedCap scToken = StakedCap(vm.envAddress("SC_TOKEN"));
        CapToken cToken = CapToken(scToken.asset());

        vm.startBroadcast();

        address owner = tx.origin;
        console.log("owner", owner);

        OFTLockbox scLockbox = new OFTLockbox(address(scToken), address(lzEndpoint), owner);
        console.log("scToken", address(scToken));
        console.log("scToken Lockbox", address(scLockbox));

        OFTLockbox cLockbox = new OFTLockbox(address(cToken), address(lzEndpoint), owner);
        console.log("cToken", address(cToken));
        console.log("cToken Lockbox", address(cLockbox));

        vm.stopBroadcast();
    }
}
