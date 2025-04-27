// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig
} from "../contracts/deploy/interfaces/DeployConfigs.sol";
import { SymbioticVaultParams } from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureDelegation } from "../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "../contracts/deploy/service/ConfigureOracle.sol";
import { ConfigureSymbioticOptIns } from "../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { DeploySymbioticVault } from "../contracts/deploy/service/providers/symbiotic/DeploySymbioticVault.sol";
import { LzAddressbook, LzUtils } from "../contracts/deploy/utils/LzUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../contracts/deploy/utils/SymbioticUtils.sol";
import { InitSymbioticVaultLiquidity } from "../test/deploy/service/provider/symbiotic/InitSymbioticVaultLiquidity.sol";
import { MockChainlinkPriceFeed } from "../test/mocks/MockChainlinkPriceFeed.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { InfraConfigSerializer } from "./config/InfraConfigSerializer.sol";
import { SymbioticAdapterConfigSerializer } from "./config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "./config/SymbioticVaultConfigSerializer.sol";
import { WalletUsersConfig } from "./config/WalletUsersConfig.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployTestnetSymbioticVault is
    Script,
    LzUtils,
    SymbioticUtils,
    WalletUsersConfig,
    ConfigureDelegation,
    DeploySymbioticVault,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    ConfigureOracle,
    InfraConfigSerializer,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer,
    InitSymbioticVaultLiquidity
{
    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;

    UsersConfig users;
    InfraConfig infra;
    ImplementationsConfig implems;
    LibsConfig libs;

    SymbioticNetworkAdapterImplementationsConfig networkAdapterImplems;
    SymbioticNetworkAdapterConfig networkAdapter;

    SymbioticVaultConfig vault;
    SymbioticNetworkRewardsConfig rewards;

    function run() external {
        uint48 vaultEpochDuration = 7 days; // mainnet & unit tests
        //uint48 vaultEpochDuration = 5 minutes; // testnet

        users = _getUsersConfig();
        (implems, libs, infra) = _readInfraConfig();
        address vault_admin = getWalletAddress();
        symbioticAb = _getSymbioticAddressbook();
        (networkAdapterImplems, networkAdapter) = _readSymbioticConfig();

        address agent = getWalletAddress();
        address restaker = getWalletAddress();

        vm.startBroadcast();

        MockERC20 stETH = new MockERC20("stETH", "stETH", 18);

        MockChainlinkPriceFeed stETHPriceFeed = new MockChainlinkPriceFeed(1000e8);

        _initChainlinkPriceOracle(libs, infra, address(stETH), address(stETHPriceFeed));

        console.log("deploying symbiotic vault");
        vault = _deploySymbioticVault(
            symbioticAb,
            SymbioticVaultParams({
                vault_admin: vault_admin,
                collateral: address(stETH),
                vaultEpochDuration: vaultEpochDuration,
                burnerRouterDelay: 0
            })
        );

        console.log("deploying symbiotic network rewards");
        rewards = _deploySymbioticRestakerRewardContract(symbioticAb, users, vault);
        _saveSymbioticVaultConfig(vault, rewards);

        console.log("init vault liquidity");
        _symbioticMintAndStakeInVault(vault.vault, restaker, 1e42);

        console.log("registering symbiotic network in vaults");
        _registerCapNetworkInVault(networkAdapter, vault);

        console.log("registering vaults in network middleware");
        _registerVaultInNetworkMiddleware(networkAdapter, vault, rewards);
        _registerAgentInNetworkMiddleware(networkAdapter, vault, agent);

        console.log("registering agents as operator");
        // _agentRegisterAsOperator(symbioticAb);
        _agentOptInToSymbioticVault(symbioticAb, vault);
        _agentOptInToSymbioticNetwork(symbioticAb, networkAdapter);

        console.log("registering vault to all agents");
        _networkOptInToSymbioticVault(networkAdapter, vault, agent);
        _symbioticVaultDelegateToAgent(vault, networkAdapter, agent, 1e42);

        console.log("init delegation");
        _addAgentToDelegationContract(infra, agent, networkAdapter.networkMiddleware);

        vm.stopBroadcast();
    }
}
