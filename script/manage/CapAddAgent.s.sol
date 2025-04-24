// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract DeployTestnetSymbioticVault is
    Script,
    DeployCapNetworkAdapter,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    SymbioticNetworkAdapterConfig networkAdapter;
    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        (, networkAdapter) = _readSymbioticConfig();

        address agent = vm.envAddress("AGENT");
        (vault, rewards) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));

        vm.startBroadcast();

        _registerAgentInNetworkMiddleware(networkAdapter, vault, agent);

        vm.stopBroadcast();
    }
}
