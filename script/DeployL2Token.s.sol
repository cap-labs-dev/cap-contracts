// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { L2Token } from "../contracts/token/L2Token.sol";
import { LzUtils } from "./util/LzUtils.sol";
import { WalletUtils } from "./util/WalletUtils.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy an L2 token contract
 */
contract DeployL2Token is Script, WalletUtils, LzUtils {
    function run() public {
        LzConfig memory config = getLzConfig(vm, block.chainid);

        vm.startBroadcast();

        address owner = getWalletAddress();
        console.log("owner", owner);

        string memory name = "Cap USD";
        string memory symbol = "cUSD";

        L2Token cToken = new L2Token(name, symbol, address(config.endpointV2), owner);
        console.log(string.concat("Bridged ", name, " ", symbol), address(cToken));

        name = string.concat("Staked ", name);
        symbol = string.concat("s", symbol);
        L2Token scToken = new L2Token(name, symbol, address(config.endpointV2), owner);
        console.log(string.concat("Bridged ", name, " ", symbol), address(scToken));

        vm.stopBroadcast();
    }
}
