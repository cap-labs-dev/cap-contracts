// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CoverageLens } from "../contracts/delegation/utils/CoverageLens.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        vm.startBroadcast();
        CoverageLens coverageLens = new CoverageLens();
        console.log("CapToken deployed to:", address(coverageLens));
        vm.stopBroadcast();
    }
}
