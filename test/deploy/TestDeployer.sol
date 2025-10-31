// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Delegation } from "../../contracts/delegation/Delegation.sol";

import { CapSymbioticVaultFactory } from "../../contracts/delegation/providers/symbiotic/CapSymbioticVaultFactory.sol";

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";

import { SymbioticAgentManager } from "../../contracts/delegation/providers/symbiotic/SymbioticAgentManager.sol";
import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";

import { FeeConfig, VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ISymbioticAgentManager } from "../../contracts/interfaces/ISymbioticAgentManager.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";

import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import {
    EigenConfig, EigenUsersConfig, EigenVaultConfig
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
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";
import { DeployCapNetworkAdapter } from "../../contracts/deploy/service/providers/symbiotic/DeployCapNetworkAdapter.sol";
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

import { InitEigenDelegations } from "./service/provider/eigen/InitEigenDelegations.sol";
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
    EigenUtils,
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
    DeployCapNetworkAdapter,
    ConfigureSymbioticOptIns,
    InitSymbioticVaultLiquidity,
    InitEigenDelegations,
    VaultConfigHelpers
{
    TestEnvConfig env;
    EigenAddressbook eigenAb;
    LzAddressbook lzAb;
    SymbioticAddressbook symbioticAb;
    ZapAddressbook zapAb;

    /// set to true to use the mock backing network
    /// makes the tests faster but does not test the full functionality
    /// TODO: remove this and create a different deployer method for each environment we need to create
    ///       this is not great as it makes the deployer harder to understand
    function useMockBackingNetwork() internal view virtual returns (bool) {
        return false;
    }

    function _deployCapTestEnvironment() internal {
        if (useMockBackingNetwork()) {
            console.log("using MOCK blockchain");
            vm.chainId(11155111);
        } else {
            console.log("using sepolia as the test blockchain");
            // we need to fork the sepolia network to deploy the symbiotic network adapter
            // hardcoding the block number to benefit from the anvil cache
            vm.createSelectFork("https://mainnet.gateway.tenderly.co", 23285216); // holesky needed to use OperatorNetworkSpecificDelegator
        }

        (env.users, env.testUsers) = _deployTestUsers();

        /// DEPLOY
        vm.startPrank(env.users.deployer);

        lzAb = _getLzAddressbook();
        symbioticAb = _getSymbioticAddressbook();
        zapAb = _getZapAddressbook();
        if (!useMockBackingNetwork()) {
            eigenAb = _getEigenAddressbook();
        }

        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.infra = _deployInfra(env.implems, env.users, 1 days);

        env.usdMocks = _deployUSDMocks();
        env.ethMocks = _deployEthMocks();
        env.permissionedMocks =
            _deployPermissionedMocks(env.infra.accessControl, env.implems.wrapper, env.users.insurance_fund);
        env.usdOracleMocks = _deployOracleMocks(env.usdMocks);
        env.ethOracleMocks = _deployOracleMocks(env.ethMocks);
        env.permissionedOracleMocks = _deployOracleMocks(env.permissionedMocks);

        console.log("deploying usdVault");
        env.usdVault =
            _deployVault(env.implems, env.infra, "Cap USD", "cUSD", env.usdOracleMocks.assets, env.users.insurance_fund);

        if (useMockBackingNetwork()) {
            console.log("skipping lzperiphery");
        } else {
            console.log("deploying lzperiphery");
            env.usdVault.lzperiphery = _deployVaultLzPeriphery(lzAb, zapAb, env.usdVault, env.users);
        }

        /// ACCESS CONTROL
        console.log("deploying access control");
        vm.startPrank(env.users.access_control_admin);
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.usdVault, env.users);

        /// SET DEPOSIT CAP
        console.log("setting deposit caps");
        vm.startPrank(env.users.vault_config_admin);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            address asset = env.usdVault.assets[i];
            CapToken(env.usdVault.capToken).setDepositCap(asset, type(uint256).max);
        }
        vm.stopPrank();

        /// ORACLE
        console.log("deploying oracle");
        vm.startPrank(env.users.oracle_admin);
        _initOracleMocks(env.usdOracleMocks, 1e8, uint256(0.1e27)); // $1.00 with 8 decimals & 10% Annualized in ray decimals
        _initOracleMocks(env.ethOracleMocks, 2600e8, uint256(0.1e27)); // $2600.00 with 8 decimals & 10% Annualized in ray decimals
        _initOracleMocks(env.permissionedOracleMocks, 1e8, uint256(0.1e27)); // $1.00 with 8 decimals & 10% Annualized in ray decimals
        _initVaultOracle(env.libs, env.infra, env.usdVault);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            address asset = env.usdVault.assets[i];
            address priceFeed = env.usdOracleMocks.chainlinkPriceFeeds[i];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, priceFeed);
        }
        for (uint256 i = 0; i < env.ethOracleMocks.assets.length; i++) {
            address asset = env.ethOracleMocks.assets[i];
            address priceFeed = env.ethOracleMocks.chainlinkPriceFeeds[i];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, priceFeed);
        }
        for (uint256 i = 0; i < env.permissionedOracleMocks.assets.length; i++) {
            address asset = env.permissionedOracleMocks.assets[i];
            address priceFeed = env.permissionedOracleMocks.chainlinkPriceFeeds[i];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, priceFeed);
        }

        if (!useMockBackingNetwork()) {
            /// cbETH for Eigen test
            address asset = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
            address priceFeed = env.ethOracleMocks.chainlinkPriceFeeds[0];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, priceFeed);
        }

        console.log("deploying rate oracle");
        vm.startPrank(env.users.rate_oracle_admin);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            _initAaveRateOracle(env.libs, env.infra, env.usdVault.assets[i], env.usdOracleMocks.aaveDataProviders[i]);
        }

        /// LENDER
        console.log("deploying lender");
        vm.startPrank(env.users.lender_admin);

        FeeConfig memory fee = FeeConfig({
            minMintFee: 0.005e27, // 0.5% minimum mint fee
            slope0: 0, // allow liquidity to be added without fee
            slope1: 0, // allow liquidity to be added without fee to start with
            mintKinkRatio: 0.85e27,
            burnKinkRatio: 0.15e27,
            optimalRatio: 0.33e27
        });

        _initVaultLender(env.usdVault, env.infra, fee);

        /// Deploy Eigen Network
        if (!useMockBackingNetwork()) {
            address eigenAdmin = makeAddr("strategy_admin");
            env.eigen.eigenImplementations = _deployEigenImplementations();
            env.eigen.eigenConfig =
                _deployEigenInfra(env.infra, env.eigen.eigenImplementations, eigenAb, env.usdVault.capToken, 7);
            vm.startPrank(env.users.access_control_admin);
            _initEigenAccessControl(env.infra, env.eigen.eigenConfig, eigenAdmin, eigenAb);
            vm.stopPrank();
            vm.startPrank(env.users.delegation_admin);
            console.log(env.eigen.eigenConfig.eigenServiceManager);
            _registerNetworkForCapDelegation(env.infra, env.eigen.eigenConfig.eigenServiceManager);
            vm.stopPrank();
            // _agentRegisterAsOperator(eigenAb, env.testUsers.agents[1]);
            address[] memory _agents = new address[](2);
            _agents[0] = env.testUsers.agents[1];
            _agents[1] = env.testUsers.agents[2];
            address[] memory _restakers = new address[](2);
            _restakers[0] = env.testUsers.restakers[1];
            _restakers[1] = env.testUsers.restakers[2];
            _registerToEigenServiceManager(eigenAb, eigenAdmin, env.eigen.eigenConfig.agentManager, _agents, _restakers);
            _initEigenDelegations(eigenAb, env.eigen.eigenConfig.eigenServiceManager, _agents, _restakers, 10);
        }

        /// Deploy Symbiotic Network Adapter
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

            _setMockNetworkMiddlewareAgentCoverage(env, env.testUsers.agents[0], 1_000_000e8);
        } else {
            /// SYMBIOTIC NETWORK ADAPTER
            console.log("deploying symbiotic cap network address");
            env.symbiotic.users.vault_admin = makeAddr("vault_admin");

            console.log("deploying symbiotic network adapter");
            vm.startPrank(env.users.deployer);
            env.symbiotic.networkAdapterImplems = _deploySymbioticNetworkAdapterImplems();
            env.symbiotic.networkAdapter = _deploySymbioticNetworkAdapterInfra(
                env.usdVault.capToken,
                env.infra,
                symbioticAb,
                env.symbiotic.networkAdapterImplems,
                SymbioticNetworkAdapterParams({ vaultEpochDuration: 7 days, feeAllowed: 1000 })
            );

            address agent = env.testUsers.agents[0];

            console.log("registering delegation network");
            vm.startPrank(env.users.delegation_admin);
            _registerNetworkForCapDelegation(env.infra, env.symbiotic.networkAdapter.networkMiddleware);

            console.log("access control mgmt");
            vm.startPrank(env.users.access_control_admin);
            _initSymbioticNetworkAdapterAccessControl(env.infra, env.symbiotic.networkAdapter, env.users);

            console.log("deploying symbiotic WETH vault");
            (SymbioticVaultConfig memory _vault, SymbioticNetworkRewardsConfig memory _rewards) =
                _deployAndConfigureTestnetSymbioticVault(env.ethMocks[0], "WETH", agent);

            _symbioticVaultConfigToEnv(_vault);
            _symbioticNetworkRewardsConfigToEnv(_rewards);

            vm.stopPrank();
        }

        // change  epoch
        _timeTravel(28 days);

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

        (address vault, address delegator, address burner, address slasher, address stakerRewarder) =
        CapSymbioticVaultFactory(env.symbiotic.networkAdapter.vaultFactory).createVault(
            env.symbiotic.users.vault_admin, collateral, agent, env.symbiotic.networkAdapter.network
        );

        _vault.vault = vault;
        _vault.collateral = collateral;
        _vault.globalReceiver = env.symbiotic.networkAdapter.networkMiddleware;
        _vault.delegator = delegator;
        _vault.burnerRouter = burner;
        _vault.slasher = slasher;
        _vault.vaultEpochDuration = 7 days;
        _rewards.stakerRewarder = stakerRewarder;

        console.log("registering vaults in network middleware");
        vm.startPrank(env.users.middleware_admin);

        ISymbioticAgentManager.AgentConfig memory agentConfig = ISymbioticAgentManager.AgentConfig({
            agent: agent,
            vault: vault,
            rewarder: stakerRewarder,
            ltv: 0.5e27,
            liquidationThreshold: 0.7e27,
            delegationRate: 0.02e27
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
