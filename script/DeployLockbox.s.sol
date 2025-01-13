// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CapToken } from "../contracts/token/CapToken.sol";
import { OFTLockbox } from "../contracts/token/OFTLockbox.sol";
import { StakedCap } from "../contracts/token/StakedCap.sol";

import { LzUtils } from "./util/LzUtils.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployLockbox is Script, LzUtils {
    function run() public {
        vm.startBroadcast();

        address lzEndpoint = _getLzConfig(vm, block.chainid).endpointV2;
        StakedCap scToken = StakedCap(vm.envAddress("SC_TOKEN"));
        CapToken cToken = CapToken(scToken.asset());

        OFTLockbox scLockbox = new OFTLockbox(address(scToken), lzEndpoint, msg.sender);
        console.log("scToken", address(scToken));
        console.log("scToken Lockbox", address(scLockbox));

        OFTLockbox cLockbox = new OFTLockbox(address(cToken), lzEndpoint, msg.sender);
        console.log("cToken", address(cToken));
        console.log("cToken Lockbox", address(cLockbox));

        vm.stopBroadcast();
    }
}
