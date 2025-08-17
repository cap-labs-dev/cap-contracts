// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SymbioticNetworkMiddleware } from "../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        vm.startBroadcast();
        SymbioticNetworkMiddleware middleware = new SymbioticNetworkMiddleware();
        console.log("SymbioticNetworkMiddleware deployed to:", address(middleware));
        vm.stopBroadcast();
        /* address vaultConfigurator = 0x29300b1d3150B4E2b12fE80BE72f365E200441EC;
        address burnerRouterFactory = 0x99F2B89fB3C363fBafD8d826E5AA77b28bAB70a0;
        address defaultStakerRewardsFactory = 0xFEB871581C2ab2e1EEe6f7dDC7e6246cFa087A23;
        address middleware = 0x8C9140Fe6650E56A0A07E86455D745f8F7843B6D;
        CapSymbioticVaultFactory factory = new CapSymbioticVaultFactory(
            vaultConfigurator, burnerRouterFactory, defaultStakerRewardsFactory, middleware
        );
        console.log("CapSymbioticVaultFactory deployed to:", address(factory));*/
    }
}
