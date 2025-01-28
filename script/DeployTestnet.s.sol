// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SymbioticVaultParams } from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { SymbioticNetworkAdapterParams } from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkRewardsConfig,
    SymbioticUsersConfig,
    SymbioticVaultConfig
} from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureAccessControl } from "../contracts/deploy/service/ConfigureAccessControl.sol";
import { ConfigureDelegation } from "../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "../contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "../contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "../contracts/deploy/service/DeployVault.sol";
import { ConfigureSymbioticOptIns } from "../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { DeploySymbioticVault } from "../contracts/deploy/service/providers/symbiotic/DeploySymbioticVault.sol";

import { LzAddressbook, LzUtils } from "../contracts/deploy/utils/LzUtils.sol";
import { ProxyUtils } from "../contracts/deploy/utils/ProxyUtils.sol";
import { ProxyUtils } from "../contracts/deploy/utils/ProxyUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../contracts/deploy/utils/SymbioticUtils.sol";
import { WalletUtils } from "../contracts/deploy/utils/WalletUtils.sol";
import { OracleMocksConfig, TestUsersConfig } from "../test/deploy/interfaces/TestDeployConfig.sol";
import { SymbioticTestEnvConfig } from "../test/deploy/interfaces/TestDeployConfig.sol";
import { DeployMocks } from "../test/deploy/service/DeployMocks.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import {
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig,
    VaultConfig
} from "../contracts/deploy/interfaces/DeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticVaultConfig
} from "../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

struct Env {
    UsersConfig users;
    TestUsersConfig testUsers;
    ImplementationsConfig implems;
    LibsConfig libs;
    InfraConfig infra;
    SymbioticTestEnvConfig symbiotic;
    OracleMocksConfig oracleMocks;
    address[] usdMocks;
    address[][] delegationMocks; // [agent][delegator]
    VaultConfig cUsdVault;
}

contract DeployTestnet is
    Script,
    LzUtils,
    SymbioticUtils,
    WalletUtils,
    DeployMocks,
    DeployInfra,
    DeployVault,
    DeployImplems,
    DeployLibs,
    ConfigureOracle,
    ConfigureDelegation,
    ConfigureAccessControl,
    DeploySymbioticVault,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns
{
    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;
    Env env;

    function log_addresses() internal view {
        console.log("env.implems.accessControl", env.implems.accessControl);
        console.log("env.implems.lender", env.implems.lender);
        console.log("env.implems.delegation", env.implems.delegation);
        console.log("env.implems.capToken", env.implems.capToken);
        console.log("env.implems.stakedCap", env.implems.stakedCap);
        console.log("env.implems.oracle", env.implems.oracle);
        console.log("env.implems.principalDebtToken", env.implems.principalDebtToken);
        console.log("env.implems.interestDebtToken", env.implems.interestDebtToken);
        console.log("env.implems.restakerDebtToken", env.implems.restakerDebtToken);

        console.log("env.libs.aaveAdapter", env.libs.aaveAdapter);
        console.log("env.libs.chainlinkAdapter", env.libs.chainlinkAdapter);
        console.log("env.libs.capTokenAdapter", env.libs.capTokenAdapter);
        console.log("env.libs.stakedCapAdapter", env.libs.stakedCapAdapter);

        console.log("infra.oracle", env.infra.oracle);
        console.log("infra.accessControl", env.infra.accessControl);
        console.log("infra.lender", env.infra.lender);
        console.log("infra.delegation", env.infra.delegation);

        console.log("env.symbiotic.users.vault_admin", env.symbiotic.users.vault_admin);
        console.log("env.symbiotic.networkAdapterImplems.network", env.symbiotic.networkAdapterImplems.network);
        console.log(
            "env.symbiotic.networkAdapterImplems.restakerRewarder",
            env.symbiotic.networkAdapterImplems.networkMiddleware
        );
        console.log("env.symbiotic.networkAdapter.network", env.symbiotic.networkAdapter.network);
        console.log("env.symbiotic.networkAdapter.networkMiddleware", env.symbiotic.networkAdapter.networkMiddleware);
        console.log("env.symbiotic.networkAdapter.slashDuration", env.symbiotic.networkAdapter.slashDuration);
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            console.log("env.symbiotic.vaults[", i, "]", env.symbiotic.vaults[i]);
            console.log("env.symbiotic.collaterals[", i, "]", env.symbiotic.collaterals[i]);
            console.log("env.symbiotic.burnerRouters[", i, "]", env.symbiotic.burnerRouters[i]);
            console.log("env.symbiotic.globalReceivers[", i, "]", env.symbiotic.globalReceivers[i]);
            console.log("env.symbiotic.delegators[", i, "]", env.symbiotic.delegators[i]);
            console.log("env.symbiotic.slashers[", i, "]", env.symbiotic.slashers[i]);
            console.log("env.symbiotic.networkRewards[", i, "]", env.symbiotic.networkRewards[i]);
            console.log("env.symbiotic.vaultEpochDurations[", i, "]", env.symbiotic.vaultEpochDurations[i]);
        }

        for (uint256 i = 0; i < env.oracleMocks.assets.length; i++) {
            console.log("env.oracleMocks.assets[", i, "]", env.oracleMocks.assets[i]);
        }
        for (uint256 i = 0; i < env.oracleMocks.aaveDataProviders.length; i++) {
            console.log("env.oracleMocks.aaveDataProviders[", i, "]", env.oracleMocks.aaveDataProviders[i]);
        }
        for (uint256 i = 0; i < env.oracleMocks.chainlinkPriceFeeds.length; i++) {
            console.log("env.oracleMocks.chainlinkPriceFeeds[", i, "]", env.oracleMocks.chainlinkPriceFeeds[i]);
        }

        for (uint256 i = 0; i < env.delegationMocks.length; i++) {
            for (uint256 j = 0; j < env.delegationMocks[i].length; j++) {
                console.log(
                    string.concat("env.delegationMocks[", Strings.toString(i), "][", Strings.toString(j), "]"),
                    env.delegationMocks[i][j]
                );
            }
        }

        console.log("env.cUsdVault.capToken", env.cUsdVault.capToken);
        console.log("env.cUsdVault.stakedCapToken", env.cUsdVault.stakedCapToken);
        console.log("env.cUsdVault.capOFTLockbox", env.cUsdVault.capOFTLockbox);
        console.log("env.cUsdVault.stakedCapOFTLockbox", env.cUsdVault.stakedCapOFTLockbox);

        for (uint256 i = 0; i < env.cUsdVault.assets.length; i++) {
            console.log("env.cUsdVault.assets[", i, "]", env.cUsdVault.assets[i]);
            console.log("env.cUsdVault.principalDebtTokens[", i, "]", env.cUsdVault.principalDebtTokens[i]);
            console.log("env.cUsdVault.restakerDebtTokens[", i, "]", env.cUsdVault.restakerDebtTokens[i]);
            console.log("env.cUsdVault.interestDebtTokens[", i, "]", env.cUsdVault.interestDebtTokens[i]);
        }
    }

    function run() external {
        vm.startBroadcast();

        // Get the broadcast address (deployer's address)
        env.users = UsersConfig({
            deployer: getWalletAddress(),
            access_control_admin: getWalletAddress(),
            address_provider_admin: getWalletAddress(),
            interest_receiver: getWalletAddress(),
            oracle_admin: getWalletAddress(),
            rate_oracle_admin: getWalletAddress(),
            vault_config_admin: getWalletAddress(),
            lender_admin: getWalletAddress(),
            delegation_admin: getWalletAddress(),
            middleware_admin: getWalletAddress(),
            staker_rewards_admin: getWalletAddress()
        });

        address[] memory agents = new address[](1);
        agents[0] = getWalletAddress();

        env.testUsers =
            TestUsersConfig({ agents: agents, stablecoin_minter: getWalletAddress(), liquidator: getWalletAddress() });

        lzAb = _getLzAddressbook();
        symbioticAb = _getSymbioticAddressbook();

        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.infra = _deployInfra(env.implems, env.users);

        env.usdMocks = _deployUSDMocks();
        env.delegationMocks = _deployDelegationMocks(env.testUsers, 3);
        env.oracleMocks = _deployOracleMocks(env.usdMocks);

        console.log("deploying vault");
        env.cUsdVault = _deployVault(lzAb, env.implems, env.infra, env.users, "Cap USD", "cUSD", env.oracleMocks.assets);

        /// ACCESS CONTROL
        console.log("deploying access control");
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.cUsdVault);

        /// ORACLE
        console.log("deploying oracle");
        _initOracleMocks(env.oracleMocks);
        _initVaultOracle(env.libs, env.infra, env.cUsdVault);
        for (uint256 i = 0; i < env.cUsdVault.assets.length; i++) {
            _initChainlinkPriceOracle(
                env.libs, env.infra, env.cUsdVault.assets[i], env.oracleMocks.chainlinkPriceFeeds[i]
            );
        }
        console.log("deploying rate oracle");
        for (uint256 i = 0; i < env.cUsdVault.assets.length; i++) {
            _initAaveRateOracle(env.libs, env.infra, env.cUsdVault.assets[i], env.oracleMocks.aaveDataProviders[i]);
        }

        /// LENDER
        console.log("deploying lender");
        _initVaultLender(env.cUsdVault, env.infra, env.users);

        /// DELEGATION
        console.log("deploying delegation");
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address agent = env.testUsers.agents[i];
            _initDelegation(env.infra, agent, env.delegationMocks[i]);
        }

        /// SYMBIOTIC NETWORK ADAPTER
        console.log("deploying symbiotic network adapter");
        env.symbiotic.users.vault_admin = getWalletAddress();
        env.symbiotic.networkAdapterImplems = _deploySymbioticNetworkAdapterImplems();
        env.symbiotic.networkAdapter = _deploySymbioticNetworkAdapterInfra(
            env.infra,
            symbioticAb,
            env.symbiotic.networkAdapterImplems,
            SymbioticNetworkAdapterParams({ vaultEpochDuration: 1 hours, slashDuration: 50 minutes })
        );

        console.log("deploying symbiotic vaults");
        _symbioticVaultConfigToEnv(
            _deploySymbioticVault(
                symbioticAb,
                SymbioticVaultParams({
                    vault_admin: env.symbiotic.users.vault_admin,
                    collateral: env.usdMocks[0],
                    vaultEpochDuration: 1 hours,
                    burnerRouterDelay: 0
                })
            )
        );

        _symbioticVaultConfigToEnv(
            _deploySymbioticVault(
                symbioticAb,
                SymbioticVaultParams({
                    vault_admin: env.symbiotic.users.vault_admin,
                    collateral: env.usdMocks[2],
                    vaultEpochDuration: 1 hours,
                    burnerRouterDelay: 0
                })
            )
        );

        console.log("deploying symbiotic network rewards");
        _symbioticNetworkRewardsConfigToEnv(
            _deploySymbioticRestakerRewardContract(symbioticAb, env.users, _getSymbioticVaultConfig(0))
        );
        _symbioticNetworkRewardsConfigToEnv(
            _deploySymbioticRestakerRewardContract(symbioticAb, env.users, _getSymbioticVaultConfig(1))
        );

        console.log("access control mgmt");
        _initSymbioticNetworkAdapterAccessControl(env.infra, env.symbiotic.networkAdapter, env.users);

        console.log("registering symbiotic network");
        _registerCapNetwork(symbioticAb, env.symbiotic.networkAdapter);

        console.log("registering symbiotic network in vaults");
        _registerCapNetworkInVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(0));
        _registerCapNetworkInVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(1));

        console.log("registering vaults in network middleware");
        _registerVaultsInNetworkMiddleware(
            env.testUsers,
            env.symbiotic.networkAdapter,
            _getSymbioticVaultConfig(0),
            _getSymbioticNetworkRewardsConfig(0)
        );
        _registerVaultsInNetworkMiddleware(
            env.testUsers,
            env.symbiotic.networkAdapter,
            _getSymbioticVaultConfig(1),
            _getSymbioticNetworkRewardsConfig(1)
        );

        console.log("registering agents as operator");
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            _agentRegisterAsOperator(symbioticAb);
            _agentOptInToSymbioticVault(symbioticAb, _getSymbioticVaultConfig(0));
            _agentOptInToSymbioticVault(symbioticAb, _getSymbioticVaultConfig(1));
            _agentOptInToSymbioticNetwork(symbioticAb, env.symbiotic.networkAdapter);
        }

        console.log("registering network in vaults");
        _networkOptInToSymbioticVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(0));
        _networkOptInToSymbioticVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(1));

        console.log("registering vaults in network");
        _symbioticVaultOptInToNetwork(_getSymbioticVaultConfig(0), env.symbiotic.networkAdapter, type(uint256).max);
        _symbioticVaultOptInToNetwork(_getSymbioticVaultConfig(1), env.symbiotic.networkAdapter, type(uint256).max);

        console.log("registering vault to all agents");
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address _agent = env.testUsers.agents[i];
            _symbioticVaultOptInToAgent(_getSymbioticVaultConfig(0), env.symbiotic.networkAdapter, _agent, 1e42);
            _symbioticVaultOptInToAgent(_getSymbioticVaultConfig(1), env.symbiotic.networkAdapter, _agent, 1e42);
        }

        vm.stopBroadcast();

        log_addresses();
    }

    function _symbioticVaultConfigToEnv(SymbioticVaultConfig memory _vault) internal {
        console.log("symbiotic vault config to env", _vault.vault);
        env.symbiotic.vaults.push(_vault.vault);
        env.symbiotic.collaterals.push(_vault.collateral);
        env.symbiotic.burnerRouters.push(_vault.burnerRouter);
        env.symbiotic.globalReceivers.push(_vault.globalReceiver);
        env.symbiotic.delegators.push(_vault.delegator);
        env.symbiotic.slashers.push(_vault.slasher);
        env.symbiotic.vaultEpochDurations.push(_vault.vaultEpochDuration);
    }

    function _getSymbioticVaultConfig(uint256 index) internal view returns (SymbioticVaultConfig memory _vault) {
        _vault.vault = env.symbiotic.vaults[index];
        _vault.collateral = env.symbiotic.collaterals[index];
        _vault.burnerRouter = env.symbiotic.burnerRouters[index];
        _vault.globalReceiver = env.symbiotic.globalReceivers[index];
        _vault.delegator = env.symbiotic.delegators[index];
        _vault.slasher = env.symbiotic.slashers[index];
        _vault.vaultEpochDuration = env.symbiotic.vaultEpochDurations[index];
    }

    function _symbioticNetworkRewardsConfigToEnv(SymbioticNetworkRewardsConfig memory _rewards) internal {
        env.symbiotic.networkRewards.push(_rewards.stakerRewarder);
    }

    function _getSymbioticNetworkRewardsConfig(uint256 index)
        internal
        view
        returns (SymbioticNetworkRewardsConfig memory _rewards)
    {
        _rewards.stakerRewarder = env.symbiotic.networkRewards[index];
    }
}
