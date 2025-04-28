// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureDelegation } from "../../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract CapAddAgent is
    Script,
    InfraConfigSerializer,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    ConfigureDelegation,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    InfraConfig infra;
    SymbioticNetworkAdapterConfig networkAdapter;
    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        (,, infra) = _readInfraConfig();
        (, networkAdapter) = _readSymbioticConfig();

        address agent = vm.envAddress("AGENT");
        (vault, rewards) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));

        vm.startBroadcast();

        _registerAgentInNetworkMiddleware(networkAdapter, vault, agent);
        _networkOptInToSymbioticVault(networkAdapter, vault, agent);
        _addAgentToDelegationContract(infra, agent, networkAdapter.networkMiddleware);

        vm.stopBroadcast();
    }
}
