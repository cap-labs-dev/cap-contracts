// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Delegation } from "../../contracts/delegation/Delegation.sol";

import { CapSymbioticVaultFactory } from "../../contracts/delegation/providers/symbiotic/CapSymbioticVaultFactory.sol";

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";

import { SymbioticAgentManager } from "../../contracts/delegation/providers/symbiotic/SymbioticAgentManager.sol";
import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import {
    SymbioticNetworkMiddleware
} from "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";

import { FeeConfig, VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ISymbioticAgentManager } from "../../contracts/interfaces/ISymbioticAgentManager.sol";
import {
    IOperatorNetworkSpecificDelegator
} from "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";

import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import {
    EigenConfig,
    EigenUsersConfig,
    EigenVaultConfig
} from "../../contracts/deploy/interfaces/EigenDeployConfig.sol";
import { SymbioticVaultParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { SymbioticNetworkAdapterParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
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
import {
    ConfigureSymbioticOptIns
} from "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployEigenAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployEigenAdapter.sol";
import {
    DeploySymbioticNetworkAdapter
} from "../../contracts/deploy/service/providers/symbiotic/DeploySymbioticNetworkAdapter.sol";
import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { SymbioticAddressbook, SymbioticUtils } from "../../contracts/deploy/utils/SymbioticUtils.sol";
import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";

import { Wrapper } from "../../contracts/token/Wrapper.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPermissionedERC20 } from "../mocks/MockPermissionedERC20.sol";
import { SymbioticTestEnvConfig, TestEnvConfig } from "./interfaces/TestDeployConfig.sol";
import { VaultConfigHelpers } from "./service/VaultConfigHelpers.sol";

import { EigenAddressbook, EigenUtils } from "../../contracts/deploy/utils/EigenUtils.sol";
import { LzAddressbook, LzUtils } from "../../contracts/deploy/utils/LzUtils.sol";
import { ZapAddressbook, ZapUtils } from "../../contracts/deploy/utils/ZapUtils.sol";
import { DeployMocks } from "./service/DeployMocks.sol";
import { DeployTestUsers } from "./service/DeployTestUsers.sol";
import { InitTestVaultLiquidity } from "./service/InitTestVaultLiquidity.sol";

import { TestHarnessConfig } from "./interfaces/TestHarnessConfig.sol";
import { InitEigenDelegations } from "./service/provider/eigen/InitEigenDelegations.sol";
import { InitSymbioticVaultLiquidity } from "./service/provider/symbiotic/InitSymbioticVaultLiquidity.sol";
import { TestHarnessConfigReader } from "./utils/TestHarnessConfigReader.sol";
import { TimeUtils } from "./utils/TimeUtils.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

/// @dev Test harness deployer.
///
/// This contract builds a full, local CAP stack for tests and returns the deployed addresses in `env`.
/// The intent is that 3rd parties can audit test behavior by reading this file top-to-bottom and seeing:
/// - where external protocol addresses come from (addressbooks),
/// - how CAP infra is deployed and wired,
/// - what scenario parameters are used (fork block, epoch durations, fees, oracle prices).
///
/// Configuration:
/// - Default values live in `config/test-harness.json` (chain-id keyed).
/// - Override hook: override `_harnessConfig()` in a derived test to tweak parameters without editing JSON.
///
/// High-level flow:
/// ```mermaid
/// flowchart TD
///   boot[LoadHarnessConfig] --> ctx[SelectForkOrMock]
///   ctx --> users[DeployTestUsers]
///   users --> addrbooks[LoadExternalAddressbooks]
///   addrbooks --> core[DeployCoreInfraAndVault]
///   core --> ac[InitAccessControlAndCaps]
///   ac --> oracles[InitOraclesAndRateOracles]
///   oracles --> providers[DeployProviders(Eigen/Symbiotic)]
///   providers --> finalize[TimeSkipAndLabel]
/// ```
contract TestDeployer is
    Test,
    // Config
    TestHarnessConfigReader,
    // External addressbooks
    LzUtils,
    ZapUtils,
    SymbioticUtils,
    EigenUtils,
    // Test helpers
    TimeUtils,
    VaultConfigHelpers,
    InitTestVaultLiquidity,
    InitSymbioticVaultLiquidity,
    InitEigenDelegations,
    DeployTestUsers,
    DeployMocks,
    // Deployment services
    DeployImplems,
    DeployLibs,
    DeployInfra,
    DeployVault,
    ConfigureOracle,
    ConfigureDelegation,
    ConfigureAccessControl,
    // Provider deployment
    DeployEigenAdapter,
    DeploySymbioticNetworkAdapter,
    ConfigureSymbioticOptIns
{
    TestEnvConfig env;
    TestHarnessConfig harness;
    bool harnessLoaded;
    EigenAddressbook eigenAb;
    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;
    ZapAddressbook zapAb;

    /// set to true to use the mock backing network
    /// makes the tests faster but does not test the full functionality
    /// TODO: remove this and create a different deployer method for each environment we need to create
    ///       this is not great as it makes the deployer harder to understand
    function useMockBackingNetwork() internal view virtual returns (bool) {
        if (harnessLoaded) return harness.fork.useMockBackingNetwork;
        return false; // backwards compatible default if `_deployCapTestEnvironment()` hasn't run yet
    }

    function _harnessConfig() internal view virtual returns (TestHarnessConfig memory) {
        // Load based on the current chainid, but allow config to choose mock mode.
        // The first load uses the pre-fork chain id, which is fine because the JSON includes both mainnet and mock keys.
        return _loadHarnessConfigOrDefault(block.chainid);
    }

    function _deployCapTestEnvironment() internal {
        _bootHarness();
        _selectForkOrMock();
        _deployUsersAndEnterDeployerPrank();
        _loadExternalAddressbooks();
        _deployCoreInfraAndVault();
        _initAccessControlAndCaps();
        _initOraclesAndRateOracles();
        _initLender();
        _deployEigenIfEnabled();
        _deploySymbioticAdapterAndVaults();
        _finalizeEnvironment();
    }

    function _bootHarness() internal {
        if (harnessLoaded) return;
        harness = _harnessConfig();
        harnessLoaded = true;
    }

    function _selectForkOrMock() internal {
        if (harness.fork.useMockBackingNetwork) {
            console.log("using MOCK backing network");
            vm.chainId(harness.fork.mockChainId);
            return;
        }

        console.log("using forked backing network");
        if (harness.fork.blockNumber == 0) {
            vm.createSelectFork(harness.fork.rpcUrl); // latest
        } else {
            vm.createSelectFork(harness.fork.rpcUrl, harness.fork.blockNumber);
        }
    }

    function _deployUsersAndEnterDeployerPrank() internal {
        (env.users, env.testUsers) = _deployTestUsers();
        vm.startPrank(env.users.deployer);
    }

    function _loadExternalAddressbooks() internal {
        if (!useMockBackingNetwork()) lzAb = _getLzAddressbook();
        symbioticAb = _getSymbioticAddressbook();
        zapAb = _getZapAddressbook();
        if (!useMockBackingNetwork()) eigenAb = _getEigenAddressbook();
    }

    function _deployCoreInfraAndVault() internal {
        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.infra = _deployInfra(env.implems, env.users, harness.infra.delegationEpochDuration);

        env.usdMocks = _deployUSDMocks();
        env.ethMocks = _deployEthMocks();
        env.permissionedMocks =
            _deployPermissionedMocks(env.infra.accessControl, env.implems.wrapper, env.users.insurance_fund);
        env.usdOracleMocks = _deployOracleMocks(env.usdMocks);
        env.ethOracleMocks = _deployOracleMocks(env.ethMocks);
        env.permissionedOracleMocks = _deployOracleMocks(env.permissionedMocks);

        console.log("deploying usdVault");
        env.usdVault = _deployVault(
            env.implems, env.infra, "Cap USD", "cUSD", env.usdOracleMocks.assets, env.users.insurance_fund
        );

        if (useMockBackingNetwork()) {
            console.log("skipping lzperiphery (mock backing network)");
        } else {
            console.log("deploying lzperiphery");
            env.usdVault.lzperiphery = _deployVaultLzPeriphery(lzAb, env.usdVault, env.users);
        }
    }

    function _initAccessControlAndCaps() internal {
        console.log("initializing access control");
        vm.startPrank(env.users.access_control_admin);
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.usdVault, env.users);

        console.log("setting deposit caps");
        vm.startPrank(env.users.vault_config_admin);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            CapToken(env.usdVault.capToken).setDepositCap(env.usdVault.assets[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    function _initOraclesAndRateOracles() internal {
        console.log("initializing oracle");
        vm.startPrank(env.users.oracle_admin);
        _initOracleMocks(env.usdOracleMocks, harness.oracle.usdPrice8, harness.oracle.usdRateRay);
        _initOracleMocks(env.ethOracleMocks, harness.oracle.ethPrice8, harness.oracle.ethRateRay);
        _initOracleMocks(
            env.permissionedOracleMocks, harness.oracle.permissionedPrice8, harness.oracle.permissionedRateRay
        );
        _initVaultOracle(env.libs, env.infra, env.usdVault);

        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            _initChainlinkPriceOracle(
                env.libs, env.infra, env.usdVault.assets[i], env.usdOracleMocks.chainlinkPriceFeeds[i]
            );
        }
        for (uint256 i = 0; i < env.ethOracleMocks.assets.length; i++) {
            _initChainlinkPriceOracle(
                env.libs, env.infra, env.ethOracleMocks.assets[i], env.ethOracleMocks.chainlinkPriceFeeds[i]
            );
        }
        for (uint256 i = 0; i < env.permissionedOracleMocks.assets.length; i++) {
            _initChainlinkPriceOracle(
                env.libs,
                env.infra,
                env.permissionedOracleMocks.assets[i],
                env.permissionedOracleMocks.chainlinkPriceFeeds[i]
            );
        }

        if (!useMockBackingNetwork() && harness.oracle.extraChainlinkAsset != address(0)) {
            _initChainlinkPriceOracle(
                env.libs, env.infra, harness.oracle.extraChainlinkAsset, env.ethOracleMocks.chainlinkPriceFeeds[0]
            );
        }

        console.log("initializing rate oracle");
        vm.startPrank(env.users.rate_oracle_admin);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            _initAaveRateOracle(env.libs, env.infra, env.usdVault.assets[i], env.usdOracleMocks.aaveDataProviders[i]);
        }
    }

    function _initLender() internal {
        console.log("initializing lender");
        vm.startPrank(env.users.lender_admin);
        _initVaultLender(env.usdVault, env.infra, harness.fee);
    }

    function _deployEigenIfEnabled() internal {
        if (useMockBackingNetwork()) return;

        console.log("deploying eigen adapter");
        address eigenAdmin = makeAddr("strategy_admin");

        env.eigen.eigenImplementations = _deployEigenImplementations();
        env.eigen.eigenConfig = _deployEigenInfra(
            env.infra, env.eigen.eigenImplementations, eigenAb, env.usdVault.capToken, harness.eigen.rewardDuration
        );

        vm.startPrank(env.users.access_control_admin);
        _initEigenAccessControl(env.infra, env.eigen.eigenConfig, eigenAdmin, eigenAb);
        vm.stopPrank();

        vm.startPrank(env.users.delegation_admin);
        _registerNetworkForCapDelegation(env.infra, env.eigen.eigenConfig.eigenServiceManager);
        vm.stopPrank();

        address[] memory agents = new address[](2);
        agents[0] = env.testUsers.agents[1];
        agents[1] = env.testUsers.agents[2];
        address[] memory restakers = new address[](2);
        restakers[0] = env.testUsers.restakers[1];
        restakers[1] = env.testUsers.restakers[2];

        _registerToEigenServiceManager(eigenAb, eigenAdmin, env.eigen.eigenConfig.agentManager, agents, restakers);
        _initEigenDelegations(
            eigenAb,
            env.eigen.eigenConfig.eigenServiceManager,
            agents,
            restakers,
            harness.eigen.delegationAmountNoDecimals
        );
    }

    function _deploySymbioticAdapterAndVaults() internal {
        // Fee recipient (used by `Delegation.distributeRewards`)
        vm.startPrank(env.users.delegation_admin);
        Delegation(env.infra.delegation).setFeeRecipient(env.usdVault.feeAuction);
        vm.stopPrank();

        if (useMockBackingNetwork()) {
            vm.startPrank(env.users.middleware_admin);
            (address networkMiddleware, address network) = _deployDelegationNetworkMock();
            env.symbiotic.networkAdapter.networkMiddleware = networkMiddleware;
            MockNetworkMiddleware(networkMiddleware).setNetwork(network);
            vm.stopPrank();

            _configureMockNetworkMiddleware(env, networkMiddleware);
            _setMockNetworkMiddlewareAgentCoverage(
                env, env.testUsers.agents[0], harness.symbiotic.mockAgentCoverageUsd8
            );
            return;
        }

        console.log("deploying symbiotic adapter");
        env.symbiotic.users.vault_admin = makeAddr("vault_admin");

        vm.startPrank(env.users.deployer);
        env.symbiotic.networkAdapterImplems = _deploySymbioticNetworkAdapterImplems();
        env.symbiotic.networkAdapter = _deploySymbioticNetworkAdapterInfra(
            env.usdVault.capToken,
            env.infra,
            symbioticAb,
            env.symbiotic.networkAdapterImplems,
            SymbioticNetworkAdapterParams({
                vaultEpochDuration: harness.symbiotic.vaultEpochDuration, feeAllowed: harness.symbiotic.feeAllowed
            })
        );

        address agent = env.testUsers.agents[0];

        vm.startPrank(env.users.delegation_admin);
        _registerNetworkForCapDelegation(env.infra, env.symbiotic.networkAdapter.networkMiddleware);

        vm.startPrank(env.users.access_control_admin);
        _initSymbioticNetworkAdapterAccessControl(env.infra, env.symbiotic.networkAdapter, env.users);

        console.log("deploying symbiotic WETH vault");
        (SymbioticVaultConfig memory vault, SymbioticNetworkRewardsConfig memory rewards) =
            _deployAndConfigureTestnetSymbioticVault(env.ethMocks[0], "WETH", agent);
        _symbioticVaultConfigToEnv(vault);
        _symbioticNetworkRewardsConfigToEnv(rewards);

        vm.startPrank(env.users.delegation_admin);
        for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
            Delegation(env.infra.delegation)
                .setCoverageCap(env.testUsers.agents[i], harness.symbiotic.defaultCoverageCapUsd8);
        }
        vm.stopPrank();
    }

    function _finalizeEnvironment() internal {
        _timeTravel(harness.scenario.postDeployTimeSkip);
        _unwrapEnvToMakeTestsReadable();
        _applyTestnetLabels();
        vm.stopPrank();
    }

    function _deployAndConfigureTestnetSymbioticVault(address collateral, string memory assetSymbol, address agent)
        internal
        returns (SymbioticVaultConfig memory _vault, SymbioticNetworkRewardsConfig memory _rewards)
    {
        console.log(string.concat("deploying symbiotic vault ", assetSymbol));
        vm.startPrank(env.symbiotic.users.vault_admin);

        console.log(env.symbiotic.users.vault_admin);

        (address vault, address delegator, address burner, address slasher, address stakerRewarder) = CapSymbioticVaultFactory(
                env.symbiotic.networkAdapter.vaultFactory
            ).createVault(env.symbiotic.users.vault_admin, collateral, agent, env.symbiotic.networkAdapter.network);

        _vault.vault = vault;
        _vault.collateral = collateral;
        _vault.globalReceiver = env.symbiotic.networkAdapter.networkMiddleware;
        _vault.delegator = delegator;
        _vault.burnerRouter = burner;
        _vault.slasher = slasher;
        _vault.vaultEpochDuration = harness.symbiotic.vaultEpochDuration;
        _rewards.stakerRewarder = stakerRewarder;

        console.log("registering vaults in network middleware");
        vm.startPrank(env.users.middleware_admin);

        ISymbioticAgentManager.AgentConfig memory agentConfig = ISymbioticAgentManager.AgentConfig({
            agent: agent,
            vault: vault,
            rewarder: stakerRewarder,
            ltv: harness.symbiotic.defaultAgentLtvRay,
            liquidationThreshold: harness.symbiotic.defaultAgentLiquidationThresholdRay,
            delegationRate: harness.symbiotic.defaultDelegationRateRay,
            coverageCap: type(uint256).max
        });

        SymbioticAgentManager(env.symbiotic.networkAdapter.agentManager).addAgent(agentConfig);
    }

    function _applyTestnetLabels() internal {
        vm.label(address(env.implems.accessControl), "AccessControlImplem");
        vm.label(address(env.implems.delegation), "DelegationImplem");
        vm.label(address(env.implems.feeAuction), "FeeAuctionImplem");
        vm.label(address(env.implems.feeReceiver), "FeeReceiverImplem");
        vm.label(address(env.implems.oracle), "OracleImplem");
        vm.label(address(env.implems.lender), "LenderImplem");
        vm.label(address(env.implems.stakedCap), "StakedCapImplem");
        vm.label(address(env.implems.capToken), "CapTokenImplem");
        vm.label(address(env.implems.wrapper), "WrapperImplem");

        vm.label(address(env.infra.accessControl), "AccessControlProxy");
        vm.label(address(env.infra.delegation), "DelegationProxy");
        vm.label(address(env.infra.oracle), "OracleProxy");
        vm.label(address(env.infra.lender), "LenderProxy");

        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            IERC20Metadata asset = IERC20Metadata(env.usdVault.assets[i]);
            IERC20Metadata debtToken = IERC20Metadata(env.usdVault.debtTokens[i]);
            vm.label(address(asset), asset.symbol());
            vm.label(address(debtToken), debtToken.symbol());
        }

        // Label vault contracts
        vm.label(address(env.usdVault.capToken), "cUSD");
        vm.label(address(env.usdVault.stakedCapToken), "scUSD");
        vm.label(address(env.usdVault.feeAuction), "cUSD_FeeAuction");
        vm.label(address(env.usdVault.feeReceiver), "cUSD_FeeReceiver");

        // Label symbiotic contracts
        if (!useMockBackingNetwork()) {
            for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
                vm.label(env.symbiotic.vaults[i], string.concat("SymbioticVault_", vm.toString(i)));
                vm.label(env.symbiotic.collaterals[i], string.concat("SymbioticCollateral_", vm.toString(i)));
                vm.label(env.symbiotic.burnerRouters[i], string.concat("SymbioticBurnerRouter_", vm.toString(i)));
                vm.label(env.symbiotic.globalReceivers[i], string.concat("SymbioticGlobalReceiver_", vm.toString(i)));
                vm.label(env.symbiotic.delegators[i], string.concat("SymbioticDelegator_", vm.toString(i)));
                vm.label(env.symbiotic.slashers[i], string.concat("SymbioticSlasher_", vm.toString(i)));
            }
        }

        vm.label(address(env.symbiotic.networkAdapter.networkMiddleware), "SymbioticNetworkMiddleware");
        vm.label(address(env.symbiotic.networkAdapter.network), "Cap_SymbioticNetwork");

        vm.label(address(env.eigen.eigenConfig.eigenServiceManager), "EigenServiceManager");

        vm.label(address(env.libs.aaveAdapter), "AaveAdapter");
        vm.label(address(env.libs.chainlinkAdapter), "ChainlinkAdapter");
        vm.label(address(env.libs.capTokenAdapter), "CapTokenAdapter");
        vm.label(address(env.libs.stakedCapAdapter), "StakedCapTokenAdapter");

        vm.label(address(usdVault.assets[0]), "USDT");
        vm.label(address(usdVault.assets[1]), "USDC");
        vm.label(address(usdVault.assets[2]), "USDX");
        vm.label(address(env.permissionedMocks[0]), "USDP");
        vm.label(address(env.permissionedMocks[1]), "WUSDP");
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

    VaultConfig usdVault;
    VaultConfig ethVault;
    MockERC20 usdt;
    MockERC20 usdc;
    MockERC20 usdx;
    MockPermissionedERC20 usdp;
    Wrapper wusdp;
    MockERC20 weth;
    CapToken cUSD;
    StakedCap scUSD;
    FeeAuction cUSDFeeAuction;

    SymbioticNetworkMiddleware middleware;
    SymbioticVaultConfig symbioticWethVault;
    SymbioticNetworkRewardsConfig symbioticWethNetworkRewards;

    Lender lender;
    Delegation delegation;
    AccessControl accessControl;

    function _unwrapEnvToMakeTestsReadable() internal {
        usdVault = env.usdVault;
        usdt = MockERC20(usdVault.assets[0]);
        usdc = MockERC20(usdVault.assets[1]);
        usdx = MockERC20(usdVault.assets[2]);
        usdp = MockPermissionedERC20(env.permissionedMocks[0]);
        wusdp = Wrapper(env.permissionedMocks[1]);
        weth = MockERC20(env.ethMocks[0]);
        cUSD = CapToken(usdVault.capToken);
        scUSD = StakedCap(usdVault.stakedCapToken);
        cUSDFeeAuction = FeeAuction(usdVault.feeAuction);

        if (!useMockBackingNetwork()) {
            middleware = SymbioticNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);
            symbioticWethVault = _getSymbioticVaultConfig(0);
            symbioticWethNetworkRewards = _getSymbioticNetworkRewardsConfig(0);
        }

        lender = Lender(env.infra.lender);
        delegation = Delegation(env.infra.delegation);
        accessControl = AccessControl(env.infra.accessControl);
    }

    // helpers

    function _getRandomAgent() internal view returns (address) {
        return _getAgent(0);
    }

    function _getAgent(uint256 index) internal view returns (address) {
        return env.testUsers.agents[index];
    }

    function _setAssetOraclePrice(address asset, int256 price) internal {
        for (uint256 i = 0; i < env.usdOracleMocks.chainlinkPriceFeeds.length; i++) {
            if (env.usdOracleMocks.assets[i] == asset) {
                vm.startPrank(env.users.oracle_admin);
                MockChainlinkPriceFeed(env.usdOracleMocks.chainlinkPriceFeeds[i]).setLatestAnswer(price);
                vm.stopPrank();
                return;
            }
        }

        for (uint256 i = 0; i < env.ethOracleMocks.chainlinkPriceFeeds.length; i++) {
            if (env.ethOracleMocks.assets[i] == asset) {
                vm.startPrank(env.users.oracle_admin);
                MockChainlinkPriceFeed(env.ethOracleMocks.chainlinkPriceFeeds[i]).setLatestAnswer(price);
                vm.stopPrank();
                return;
            }
        }

        revert("Asset not found");
    }

    function _grantAccess(bytes4 _selector, address _contract, address _account) internal {
        vm.startPrank(env.users.access_control_admin);
        accessControl.grantAccess(_selector, _contract, _account);
        vm.stopPrank();
    }
}
