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

import { PreMainnetImplementationsConfig } from "../contracts/deploy/interfaces/DeployConfigs.sol";
import { PreMainnetInfraConfig } from "../contracts/deploy/interfaces/DeployConfigs.sol";

import { Script } from "forge-std/Script.sol";

import { stdJson } from "forge-std/StdJson.sol";
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
    VaultConfig cUsdVault;
    PreMainnetImplementationsConfig preMainnetImplementations;
    PreMainnetInfraConfig preMainnetInfra;
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
    string constant OUTPUT_PATH_FROM_PROJECT_ROOT = "config/cap-testnet.json";

    using stdJson for string;

    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;
    Env env;

    function log_addresses() internal {
        string memory json = "output";

        vm.serializeAddress(json, "env.implems.accessControl", env.implems.accessControl);
        vm.serializeAddress(json, "env.implems.lender", env.implems.lender);
        vm.serializeAddress(json, "env.implems.delegation", env.implems.delegation);
        vm.serializeAddress(json, "env.implems.capToken", env.implems.capToken);
        vm.serializeAddress(json, "env.implems.stakedCap", env.implems.stakedCap);
        vm.serializeAddress(json, "env.implems.oracle", env.implems.oracle);
        vm.serializeAddress(json, "env.implems.principalDebtToken", env.implems.principalDebtToken);
        vm.serializeAddress(json, "env.implems.interestDebtToken", env.implems.interestDebtToken);
        vm.serializeAddress(json, "env.implems.restakerDebtToken", env.implems.restakerDebtToken);

        vm.serializeAddress(json, "env.libs.aaveAdapter", env.libs.aaveAdapter);
        vm.serializeAddress(json, "env.libs.chainlinkAdapter", env.libs.chainlinkAdapter);
        vm.serializeAddress(json, "env.libs.capTokenAdapter", env.libs.capTokenAdapter);
        vm.serializeAddress(json, "env.libs.stakedCapAdapter", env.libs.stakedCapAdapter);

        vm.serializeAddress(json, "env.infra.oracle", env.infra.oracle);
        vm.serializeAddress(json, "env.infra.accessControl", env.infra.accessControl);
        vm.serializeAddress(json, "env.infra.lender", env.infra.lender);
        vm.serializeAddress(json, "env.infra.delegation", env.infra.delegation);

        vm.serializeAddress(json, "env.symbiotic.users.vault_admin", env.symbiotic.users.vault_admin);
        vm.serializeAddress(
            json, "env.symbiotic.networkAdapterImplems.network", env.symbiotic.networkAdapterImplems.network
        );
        vm.serializeAddress(
            json,
            "env.symbiotic.networkAdapterImplems.restakerRewarder",
            env.symbiotic.networkAdapterImplems.networkMiddleware
        );
        vm.serializeAddress(json, "env.symbiotic.networkAdapter.network", env.symbiotic.networkAdapter.network);
        vm.serializeAddress(
            json, "env.symbiotic.networkAdapter.networkMiddleware", env.symbiotic.networkAdapter.networkMiddleware
        );
        vm.serializeUint(json, "env.symbiotic.networkAdapter.slashDuration", env.symbiotic.networkAdapter.slashDuration);
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            vm.serializeAddress(
                json, string.concat("env.symbiotic.vaults[", Strings.toString(i), "]"), env.symbiotic.vaults[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.symbiotic.collaterals[", Strings.toString(i), "]"),
                env.symbiotic.collaterals[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.symbiotic.burnerRouters[", Strings.toString(i), "]"),
                env.symbiotic.burnerRouters[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.symbiotic.globalReceivers[", Strings.toString(i), "]"),
                env.symbiotic.globalReceivers[i]
            );
            vm.serializeAddress(
                json, string.concat("env.symbiotic.delegators[", Strings.toString(i), "]"), env.symbiotic.delegators[i]
            );
            vm.serializeAddress(
                json, string.concat("env.symbiotic.slashers[", Strings.toString(i), "]"), env.symbiotic.slashers[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.symbiotic.networkRewards[", Strings.toString(i), "]"),
                env.symbiotic.networkRewards[i]
            );
            vm.serializeUint(
                json,
                string.concat("env.symbiotic.vaultEpochDurations[", Strings.toString(i), "]"),
                env.symbiotic.vaultEpochDurations[i]
            );
        }

        for (uint256 i = 0; i < env.oracleMocks.assets.length; i++) {
            vm.serializeAddress(
                json, string.concat("env.oracleMocks.assets[", Strings.toString(i), "]"), env.oracleMocks.assets[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.oracleMocks.aaveDataProviders[", Strings.toString(i), "]"),
                env.oracleMocks.aaveDataProviders[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.oracleMocks.chainlinkPriceFeeds[", Strings.toString(i), "]"),
                env.oracleMocks.chainlinkPriceFeeds[i]
            );
        }

        vm.serializeAddress(json, "env.cUsdVault.capToken", env.cUsdVault.capToken);
        vm.serializeAddress(json, "env.cUsdVault.stakedCapToken", env.cUsdVault.stakedCapToken);
        vm.serializeAddress(json, "env.cUsdVault.capOFTLockbox", env.cUsdVault.capOFTLockbox);
        vm.serializeAddress(json, "env.cUsdVault.stakedCapOFTLockbox", env.cUsdVault.stakedCapOFTLockbox);

        for (uint256 i = 0; i < env.cUsdVault.assets.length; i++) {
            vm.serializeAddress(
                json, string.concat("env.cUsdVault.assets[", Strings.toString(i), "]"), env.cUsdVault.assets[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.cUsdVault.principalDebtTokens[", Strings.toString(i), "]"),
                env.cUsdVault.principalDebtTokens[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.cUsdVault.restakerDebtTokens[", Strings.toString(i), "]"),
                env.cUsdVault.restakerDebtTokens[i]
            );
            vm.serializeAddress(
                json,
                string.concat("env.cUsdVault.interestDebtTokens[", Strings.toString(i), "]"),
                env.cUsdVault.interestDebtTokens[i]
            );
        }

        vm.serializeAddress(
            json, "env.preMainnetImplementations.preMainnetVault", env.preMainnetImplementations.preMainnetVault
        );

        json = vm.serializeAddress(json, "env.preMainnetInfra.preMainnetVault", env.preMainnetInfra.preMainnetVault);
        console.log(json);
        vm.writeFile(OUTPUT_PATH_FROM_PROJECT_ROOT, json);
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
        env.oracleMocks = _deployOracleMocks(env.usdMocks);

        console.log("deploying vault");
        env.cUsdVault = _deployVault(lzAb, env.implems, env.infra, env.users, "Cap USD", "cUSD", env.oracleMocks.assets);
        // env.cEthVault = _deployVault(lzAb, env.implems, env.infra, env.users, "Cap ETH", "cETH", env.oracleMocks.assets);

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

        console.log("init delegation");
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address agent = env.testUsers.agents[i];
            _initDelegationAgent(env.infra, agent);
            _initDelegationAgentDelegator(env.infra, agent, env.symbiotic.networkAdapter.networkMiddleware);
        }

        /// PRE-MAINNET
        console.log("deploying pre-mainnet infra");
        LzAddressbook memory dstAddressbook = _getLzAddressbook(421614);
        env.preMainnetImplementations = _deployPreMainnetImplementations(lzAb);
        env.preMainnetInfra =
            _deployPreMainnetInfra(dstAddressbook, env.preMainnetImplementations, env.usdMocks[1], /* usdc */ 30 days);

        log_addresses();
        vm.stopBroadcast();
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
