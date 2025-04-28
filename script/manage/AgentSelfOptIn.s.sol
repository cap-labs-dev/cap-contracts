// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract AgentSelfOptIn is
    Script,
    SymbioticUtils,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    SymbioticAddressbook symbioticAb;

    SymbioticNetworkAdapterConfig networkAdapter;

    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        symbioticAb = _getSymbioticAddressbook();
        (, networkAdapter) = _readSymbioticConfig();

        (vault, rewards) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));

        vm.startBroadcast();

        _agentRegisterAsOperator(symbioticAb);
        _agentOptInToSymbioticVault(symbioticAb, vault);
        _agentOptInToSymbioticNetwork(symbioticAb, networkAdapter);

        vm.stopBroadcast();
    }
}
