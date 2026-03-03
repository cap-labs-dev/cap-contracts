// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TempoBridgeUpgradeable } from "../contracts/token/TempoBridgeUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployTempo is Script {
    function run() external {
        vm.startBroadcast();

        address delegate = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
        address token = address(0x20C0000000000000000000000520792DcCccCccC);
        address endpoint = address(0x8bC1e36F015b9902B54b1387A4d733cebc2f5A4e);

        TempoBridgeUpgradeable tempoBridgeImpl = new TempoBridgeUpgradeable(endpoint);

        // First, encode the initialize function call with all parameters
        bytes memory initializeCalldata = abi.encodeWithSignature("initialize(address,address)", token, delegate);

        address tempoBridge = address(new ERC1967Proxy(address(tempoBridgeImpl), initializeCalldata));

        console.log("Tempo Bridge implementation deployed at", address(tempoBridgeImpl));
        console.log("Tempo Bridge deployed at", tempoBridge);
        vm.stopBroadcast();
    }
}
