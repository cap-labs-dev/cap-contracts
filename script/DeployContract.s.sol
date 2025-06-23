// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DebtToken } from "../contracts/lendingPool/tokens/DebtToken.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        vm.startBroadcast();
        DebtToken debtToken = new DebtToken();
        console.log("DebtToken deployed to:", address(debtToken));
        vm.stopBroadcast();
    }
}
