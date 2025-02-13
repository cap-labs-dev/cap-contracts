// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";

import { SymbioticVaultParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { SymbioticNetworkAdapterParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkRewardsConfig,
    SymbioticUsersConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureAccessControl } from "../../contracts/deploy/service/ConfigureAccessControl.sol";
import { ConfigureDelegation } from "../../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "../../contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "../../contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "../../contracts/deploy/service/DeployVault.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
import { DeploySymbioticVault } from "../../contracts/deploy/service/providers/symbiotic/DeploySymbioticVault.sol";
import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";
import { FeeAuction } from "../../contracts/lendingPool/FeeAuction.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SymbioticTestEnvConfig, TestEnvConfig } from "./interfaces/TestDeployConfig.sol";

import { LzAddressbook, LzUtils } from "../../contracts/deploy/utils/LzUtils.sol";
import { ZapAddressbook, ZapUtils } from "../../contracts/deploy/utils/ZapUtils.sol";
import { DeployMocks } from "./service/DeployMocks.sol";
import { DeployTestUsers } from "./service/DeployTestUsers.sol";
import { InitTestVaultLiquidity } from "./service/InitTestVaultLiquidity.sol";
import { InitSymbioticVaultLiquidity } from "./service/provider/symbiotic/InitSymbioticVaultLiquidity.sol";
import { TimeUtils } from "./utils/TimeUtils.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract TestDeployer is
    Test,
    LzUtils,
    SymbioticUtils,
    TimeUtils,
    ZapUtils,
    DeployMocks,
    DeployInfra,
    DeployVault,
    DeployImplems,
    DeployLibs,
    ConfigureOracle,
    ConfigureDelegation,
    ConfigureAccessControl,
    DeployTestUsers,
    InitTestVaultLiquidity,
    DeploySymbioticVault,
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    InitSymbioticVaultLiquidity
{
    TestEnvConfig env;

    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;
    ZapAddressbook zapAb;

    function _deployCapTestEnvironment() internal {
        // we need to fork the sepolia network to deploy the symbiotic network adapter
        // hardcoding the block number to benefit from the anvil cache
        vm.createSelectFork("sepolia", 7699085);

        (env.users, env.testUsers) = _deployTestUsers();

        /// DEPLOY
        vm.startPrank(env.users.deployer);

        lzAb = _getLzAddressbook();
        symbioticAb = _getSymbioticAddressbook();
        zapAb = _getZapAddressbook();

        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.infra = _deployInfra(env.implems, env.users);

        env.usdMocks = _deployUSDMocks();
        env.ethMock = _deployEthMock();
        env.oracleMocks = _deployOracleMocks(env.usdMocks);

        console.log("deploying vault");
        env.vault = _deployVault(env.implems, env.infra, "Cap USD", "cUSD", env.oracleMocks.assets);
        env.vault.lzperiphery = _deployVaultLzPeriphery(lzAb, zapAb, env.vault, env.users);

        /// ACCESS CONTROL
        console.log("deploying access control");
        vm.startPrank(env.users.access_control_admin);
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.vault);

        /// ORACLE
        console.log("deploying oracle");
        vm.startPrank(env.users.oracle_admin);
        _initOracleMocks(env.oracleMocks);
        _initVaultOracle(env.libs, env.infra, env.vault);
        for (uint256 i = 0; i < env.vault.assets.length; i++) {
            _initChainlinkPriceOracle(env.libs, env.infra, env.vault.assets[i], env.oracleMocks.chainlinkPriceFeeds[i]);
        }
        _initChainlinkPriceOracle(
            env.libs, env.infra, env.ethMock, env.oracleMocks.chainlinkPriceFeeds[env.oracleMocks.assets.length]
        ); // weth

        console.log("deploying rate oracle");
        vm.startPrank(env.users.rate_oracle_admin);
        for (uint256 i = 0; i < env.vault.assets.length; i++) {
            _initAaveRateOracle(env.libs, env.infra, env.vault.assets[i], env.oracleMocks.aaveDataProviders[i]);
        }

        /// LENDER
        console.log("deploying lender");
        vm.startPrank(env.users.lender_admin);
        _initVaultLender(env.vault, env.infra);

        /// SYMBIOTIC NETWORK ADAPTER
        console.log("deploying symbiotic cap network address");
        env.symbiotic.users.vault_admin = makeAddr("vault_admin");

        console.log("deploying symbiotic network adapter");
        vm.startPrank(env.users.deployer);
        env.symbiotic.networkAdapterImplems = _deploySymbioticNetworkAdapterImplems();
        env.symbiotic.networkAdapter = _deploySymbioticNetworkAdapterInfra(
            env.infra,
            symbioticAb,
            env.symbiotic.networkAdapterImplems,
            SymbioticNetworkAdapterParams({ vaultEpochDuration: 7 days, feeAllowed: 1000 })
        );

        console.log("deploying symbiotic vaults");
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultConfigToEnv(
            _deploySymbioticVault(
                symbioticAb,
                SymbioticVaultParams({
                    vault_admin: env.symbiotic.users.vault_admin,
                    collateral: env.ethMock,
                    vaultEpochDuration: 7 days,
                    burnerRouterDelay: 0
                })
            )
        );

        console.log("deployed vault 2", env.symbiotic.vaults[0]);
        _symbioticVaultConfigToEnv(
            _deploySymbioticVault(
                symbioticAb,
                SymbioticVaultParams({
                    vault_admin: env.symbiotic.users.vault_admin,
                    collateral: env.usdMocks[0],
                    vaultEpochDuration: 14 days,
                    burnerRouterDelay: 0
                })
            )
        );

        console.log("deploying symbiotic network rewards");
        vm.startPrank(env.users.staker_rewards_admin);
        _symbioticNetworkRewardsConfigToEnv(
            _deploySymbioticRestakerRewardContract(symbioticAb, env.users, _getSymbioticVaultConfig(0))
        );
        _symbioticNetworkRewardsConfigToEnv(
            _deploySymbioticRestakerRewardContract(symbioticAb, env.users, _getSymbioticVaultConfig(1))
        );

        console.log("access control mgmt");
        vm.startPrank(env.users.access_control_admin);
        _initSymbioticNetworkAdapterAccessControl(env.infra, env.symbiotic.networkAdapter, env.users);

        console.log("registering symbiotic network");
        vm.startPrank(env.users.middleware_admin);
        _registerCapNetwork(symbioticAb, env.symbiotic.networkAdapter);

        console.log("registering symbiotic network in vaults");
        vm.startPrank(env.symbiotic.users.vault_admin);
        _registerCapNetworkInVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(0));
        _registerCapNetworkInVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(1));

        console.log("registering vaults in network middleware");
        vm.startPrank(env.users.middleware_admin);
        _registerVaultsInNetworkMiddleware(
            env.symbiotic.networkAdapter,
            _getSymbioticVaultConfig(0),
            _getSymbioticNetworkRewardsConfig(0),
            env.testUsers.agents
        );
        _registerVaultsInNetworkMiddleware(
            env.symbiotic.networkAdapter,
            _getSymbioticVaultConfig(1),
            _getSymbioticNetworkRewardsConfig(1),
            env.testUsers.agents
        );

        console.log("registering agents as operator");
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            vm.startPrank(env.testUsers.agents[i]);
            _agentRegisterAsOperator(symbioticAb);
            _agentOptInToSymbioticVault(symbioticAb, _getSymbioticVaultConfig(0));
            _agentOptInToSymbioticVault(symbioticAb, _getSymbioticVaultConfig(1));
            _agentOptInToSymbioticNetwork(symbioticAb, env.symbiotic.networkAdapter);
        }

        console.log("registering network in vaults");
        vm.startPrank(env.users.middleware_admin);
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address _agent = env.testUsers.agents[i];
            _networkOptInToSymbioticVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(0), _agent);
            _networkOptInToSymbioticVault(env.symbiotic.networkAdapter, _getSymbioticVaultConfig(1), _agent);
        }

        console.log("vaults delegating to agents");
        vm.startPrank(env.symbiotic.users.vault_admin);
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address _agent = env.testUsers.agents[i];
            _symbioticVaultDelegateToAgent(
                _getSymbioticVaultConfig(0), env.symbiotic.networkAdapter, _agent, type(uint256).max
            );
            _symbioticVaultDelegateToAgent(
                _getSymbioticVaultConfig(1), env.symbiotic.networkAdapter, _agent, type(uint256).max
            );
        }

        console.log("init delegation");
        vm.startPrank(env.users.delegation_admin);
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            address agent = env.testUsers.agents[i];
            _initDelegationAgent(env.infra, agent);
            _initDelegationAgentDelegator(env.infra, agent, env.symbiotic.networkAdapter.networkMiddleware);
        }

        // change  epoch
        _timeTravel(28 days);

        _unwrapEnvToMakeTestsReadable();
        _applyTestnetLabels();
    }

    function _applyTestnetLabels() internal {
        vm.label(address(env.implems.accessControl), "AccessControlImplem");
        vm.label(address(env.implems.delegation), "DelegationImplem");
        vm.label(address(env.implems.feeAuction), "FeeAuctionImplem");
        vm.label(address(env.implems.oracle), "OracleImplem");
        vm.label(address(env.implems.lender), "LenderImplem");
        vm.label(address(env.implems.stakedCap), "StakedCapImplem");
        vm.label(address(env.implems.capToken), "CapTokenImplem");

        vm.label(address(env.infra.accessControl), "AccessControlProxy");
        vm.label(address(env.infra.delegation), "DelegationProxy");
        vm.label(address(env.infra.oracle), "OracleProxy");
        vm.label(address(env.infra.lender), "LenderProxy");

        for (uint256 i = 0; i < env.vault.assets.length; i++) {
            vm.label(address(env.vault.assets[i]), IERC20Metadata(env.vault.assets[i]).symbol());
            vm.label(
                address(env.vault.principalDebtTokens[i]), IERC20Metadata(env.vault.principalDebtTokens[i]).symbol()
            );
            vm.label(address(env.vault.restakerDebtTokens[i]), IERC20Metadata(env.vault.restakerDebtTokens[i]).symbol());
            vm.label(address(env.vault.interestDebtTokens[i]), IERC20Metadata(env.vault.interestDebtTokens[i]).symbol());
        }

        // Label vault contracts
        vm.label(address(env.vault.capToken), "cUSD");
        vm.label(address(env.vault.stakedCapToken), "scUSD");
        vm.label(address(env.vault.feeAuction), "FeeAuction");

        // Label symbiotic contracts
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            vm.label(env.symbiotic.vaults[i], string.concat("SymbioticVault_", vm.toString(i)));
            vm.label(env.symbiotic.collaterals[i], string.concat("SymbioticCollateral_", vm.toString(i)));
            vm.label(env.symbiotic.burnerRouters[i], string.concat("SymbioticBurnerRouter_", vm.toString(i)));
            vm.label(env.symbiotic.globalReceivers[i], string.concat("SymbioticGlobalReceiver_", vm.toString(i)));
            vm.label(env.symbiotic.delegators[i], string.concat("SymbioticDelegator_", vm.toString(i)));
            vm.label(env.symbiotic.slashers[i], string.concat("SymbioticSlasher_", vm.toString(i)));
        }

        vm.label(address(env.symbiotic.networkAdapter.networkMiddleware), "SymbioticNetworkMiddleware");
        vm.label(address(env.symbiotic.networkAdapter.network), "Cap_SymbioticNetwork");

        vm.label(address(env.libs.aaveAdapter), "AaveAdapter");
        vm.label(address(env.libs.chainlinkAdapter), "ChainlinkAdapter");
        vm.label(address(env.libs.capTokenAdapter), "CapTokenAdapter");
        vm.label(address(env.libs.stakedCapAdapter), "StakedCapTokenAdapter");

        vm.label(address(vault.assets[0]), "USDT");
        vm.label(address(vault.assets[1]), "USDC");
        vm.label(address(vault.assets[2]), "USDX");
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

    VaultConfig vault;
    MockERC20 usdt;
    MockERC20 usdc;
    MockERC20 usdx;
    MockERC20 weth;
    CapToken cUSD;
    StakedCap scUSD;

    NetworkMiddleware middleware;
    SymbioticVaultConfig symbioticWethVault;
    SymbioticVaultConfig symbioticUsdtVault;
    SymbioticNetworkRewardsConfig symbioticWethNetworkRewards;
    SymbioticNetworkRewardsConfig symbioticUsdtNetworkRewards;

    Lender lender;
    Delegation delegation;
    FeeAuction feeAuction;

    function _unwrapEnvToMakeTestsReadable() internal {
        vault = env.vault;
        usdt = MockERC20(vault.assets[0]);
        usdc = MockERC20(vault.assets[1]);
        usdx = MockERC20(vault.assets[2]);
        weth = MockERC20(env.ethMock);
        cUSD = CapToken(vault.capToken);
        scUSD = StakedCap(vault.stakedCapToken);
        feeAuction = FeeAuction(vault.feeAuction);

        middleware = NetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);
        symbioticWethVault = _getSymbioticVaultConfig(0);
        symbioticUsdtVault = _getSymbioticVaultConfig(1);
        symbioticWethNetworkRewards = _getSymbioticNetworkRewardsConfig(0);
        symbioticUsdtNetworkRewards = _getSymbioticNetworkRewardsConfig(1);

        lender = Lender(env.infra.lender);
        delegation = Delegation(env.infra.delegation);
    }
}
