// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract CapAddVault is
    Script,
    SymbioticUtils,
    DeployCapNetworkAdapter,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    SymbioticAddressbook symbioticAb;

    SymbioticNetworkAdapterImplementationsConfig networkAdapterImplems;
    SymbioticNetworkAdapterConfig networkAdapter;

    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        symbioticAb = _getSymbioticAddressbook();
        (networkAdapterImplems, networkAdapter) = _readSymbioticConfig();

        (vault, rewards) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));

        vm.startBroadcast();

        _registerVaultInNetworkMiddleware(networkAdapter, vault, rewards);

        vm.stopBroadcast();
    }
}
