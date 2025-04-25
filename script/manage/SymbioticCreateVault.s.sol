// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UsersConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { SymbioticVaultParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { DeploySymbioticVault } from "../../contracts/deploy/service/providers/symbiotic/DeploySymbioticVault.sol";
import { LzUtils } from "../../contracts/deploy/utils/LzUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { WalletUsersConfig } from "../config/WalletUsersConfig.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract SymbioticCreateVault is
    Script,
    LzUtils,
    SymbioticUtils,
    WalletUsersConfig,
    DeploySymbioticVault,
    DeployCapNetworkAdapter,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer
{
    SymbioticAddressbook symbioticAb;
    UsersConfig users;

    SymbioticNetworkAdapterImplementationsConfig networkAdapterImplems;
    SymbioticNetworkAdapterConfig networkAdapter;

    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        users = _getUsersConfig();
        address vault_admin = getWalletAddress();
        symbioticAb = _getSymbioticAddressbook();
        (networkAdapterImplems, networkAdapter) = _readSymbioticConfig();

        vm.startBroadcast();

        address collateral = vm.envAddress("COLLATERAL");

        console.log("deploying symbiotic vault");
        vault = _deploySymbioticVault(
            symbioticAb,
            SymbioticVaultParams({
                vault_admin: vault_admin,
                collateral: collateral,
                vaultEpochDuration: 14 days,
                burnerRouterDelay: 0
            })
        );

        console.log("deploying symbiotic network rewards");
        rewards = _deploySymbioticRestakerRewardContract(symbioticAb, users, vault);
        _saveSymbioticVaultConfig(vault, rewards);

        console.log("registering symbiotic network in vaults");
        _registerCapNetworkInVault(networkAdapter, vault);

        vm.stopBroadcast();
    }
}
