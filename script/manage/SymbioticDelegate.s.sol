// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SymbioticNetworkAdapterConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract SymbioticDelegate is
    Script,
    ConfigureSymbioticOptIns,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    SymbioticNetworkAdapterConfig networkAdapter;
    SymbioticVaultConfig vault;

    function run() external {
        (, networkAdapter) = _readSymbioticConfig();

        (vault,) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));
        address agent = vm.envAddress("AGENT");
        uint256 amount = vm.envUint("AMOUNT");

        vm.startBroadcast();

        _symbioticVaultDelegateToAgent(vault, networkAdapter, agent, amount);

        vm.stopBroadcast();
    }
}
