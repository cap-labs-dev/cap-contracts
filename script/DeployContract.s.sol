// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapToken } from "../contracts/token/CapToken.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        vm.startBroadcast();
        CapToken capToken = new CapToken();
        console.log("CapToken deployed to:", address(capToken));
        vm.stopBroadcast();
    }
}
