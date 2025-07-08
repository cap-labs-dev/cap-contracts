// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapToken } from "../contracts/token/CapToken.sol";
import { StakedCap } from "../contracts/token/StakedCap.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployCreateX is Script {
    function run() external {
        vm.startBroadcast();

        // Get the implementation contract address that will be used with the proxy
        // Replace this with your actual implementation contract address
        address implementation = address(0x9C3a8aA28E0388E89302390695478C8D00a7dBbB); // Example implementation address

        address _accessControl = address(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        address _asset = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
        uint256 _lockDuration = 1 days;

        // Generate the init code (bytecode) for ERC1967Proxy
        bytes memory initCode = type(ERC1967Proxy).creationCode;

        // Generate the initialization data for the proxy
        // First, encode the initialize function call with all parameters
        bytes memory initializeCalldata =
            abi.encodeWithSignature("initialize(address,address,uint256)", _accessControl, _asset, _lockDuration);

        // This is the constructor arguments for ERC1967Proxy: implementation address and initialization call data
        bytes memory constructorArgs = abi.encode(implementation, initializeCalldata);

        // Combine the init code with the encoded constructor arguments
        bytes memory proxyBytecode = abi.encodePacked(initCode, constructorArgs);

        console.logBytes(proxyBytecode);

        vm.stopBroadcast();
    }
}
