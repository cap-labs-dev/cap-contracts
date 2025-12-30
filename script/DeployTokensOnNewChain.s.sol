// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { L2TokenUpgradeable } from "../contracts/token/L2TokenUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

interface ICreateX {
    function deployCreate3(bytes32 _salt, bytes memory _initCode) external payable returns (address);
}

contract DeployTokensOnNewChain is Script {
    function run() external {
        vm.startBroadcast();

        ICreateX createX = ICreateX(address(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed));

        // Get the implementation contract address that will be used with the proxy
        // Replace this with your actual implementation contract address
        address endpoint = address(0x6F475642a6e85809B1c36Fa62763669b1b48DD5B);
        address implementation = address(new L2TokenUpgradeable(endpoint));
        console.log("Implementation Deployed at", implementation);

        // Generate the init code (bytecode) for ERC1967Proxy
        bytes memory initCode = type(ERC1967Proxy).creationCode;

        string memory name = "Cap USD";
        string memory symbol = "cUSD";
        bytes32 salt = bytes32(0xc1ab5a9593e6e1662a9a44f84df4f31fc8a76b5200d6008e500c5cff027dd1cf);
        // cap msig
        address delegate = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);

        // Generate the initialization data for the proxy
        // First, encode the initialize function call with all parameters
        bytes memory initializeCalldata =
            abi.encodeWithSignature("initialize(string,string,address)", name, symbol, delegate);

        // This is the constructor arguments for ERC1967Proxy: implementation address and initialization call data
        bytes memory constructorArgs = abi.encode(implementation, initializeCalldata);

        // Combine the init code with the encoded constructor arguments
        bytes memory proxyBytecode = abi.encodePacked(initCode, constructorArgs);

        address cusd = createX.deployCreate3(salt, proxyBytecode);

        console.log("Cap USD deployed at", cusd);

        // Deploy staked cap token
        name = "Staked Cap USD";
        symbol = "stcUSD";
        salt = bytes32(0xc1ab5a9593e6e1662a9a44f84df4f31fc8a76b5200f74c0677397bca01f16c25);
        delegate = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);

        // Generate the initialization data for the proxy
        // First, encode the initialize function call with all parameters
        initializeCalldata = abi.encodeWithSignature("initialize(string,string,address)", name, symbol, delegate);

        // This is the constructor arguments for ERC1967Proxy: implementation address and initialization call data
        constructorArgs = abi.encode(implementation, initializeCalldata);

        // Combine the init code with the encoded constructor arguments
        proxyBytecode = abi.encodePacked(initCode, constructorArgs);

        address stcUSD = createX.deployCreate3(salt, proxyBytecode);

        console.log("Staked Cap USD deployed at", stcUSD);

        vm.stopBroadcast();
    }
}
