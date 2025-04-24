// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { SymbioticVaultParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { ConfigureDelegation } from "../../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";

import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { DeploySymbioticVault } from "../../contracts/deploy/service/providers/symbiotic/DeploySymbioticVault.sol";

import { LzAddressbook, LzUtils } from "../../contracts/deploy/utils/LzUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";

import {
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig
} from "../../contracts/deploy/interfaces/DeployConfigs.sol";

import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { WalletUsersConfig } from "../config/WalletUsersConfig.sol";

contract DeployTestnetSymbioticVault is
    Script,
    LzUtils,
    SymbioticUtils,
    WalletUsersConfig,
    ConfigureDelegation,
    DeploySymbioticVault,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    InfraConfigSerializer,
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
