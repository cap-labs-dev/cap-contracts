// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseSetup } from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";

// Managers
import { ActorManager } from "@recon/ActorManager.sol";
import { AssetManager } from "@recon/AssetManager.sol";

// Helpers
import { Utils } from "@recon/Utils.sol";

// Your deps

import { AccessControl } from "contracts/access/AccessControl.sol";
import { Delegation } from "contracts/delegation/Delegation.sol";
import { FeeConfig, InfraConfig, UsersConfig } from "contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureDelegation } from "contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "contracts/deploy/service/DeployVault.sol";
import { FeeAuction } from "contracts/feeAuction/FeeAuction.sol";

import { IPriceOracle } from "contracts/interfaces/IPriceOracle.sol";
import { IRateOracle } from "contracts/interfaces/IRateOracle.sol";
import { Lender } from "contracts/lendingPool/Lender.sol";
import { DebtToken } from "contracts/lendingPool/tokens/DebtToken.sol";
import { Oracle } from "contracts/oracle/Oracle.sol";
import { CapToken } from "contracts/token/CapToken.sol";
import { StakedCap } from "contracts/token/StakedCap.sol";
import { OracleMocksConfig, TestEnvConfig } from "test/deploy/interfaces/TestDeployConfig.sol";
import { MockAaveDataProvider } from "test/mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "test/mocks/MockChainlinkPriceFeed.sol";
import { MockNetworkMiddleware } from "test/mocks/MockNetworkMiddleware.sol";
import { VaultManager } from "test/recon/helpers/VaultManager.sol";

abstract contract Setup is
    BaseSetup,
    ActorManager,
    AssetManager,
    VaultManager,
    Utils,
    DeployInfra,
    DeployVault,
    DeployImplems,
    DeployLibs,
    ConfigureOracle,
    ConfigureDelegation
{
    // ConfigureAccessControl

    TestEnvConfig env;

    AccessControl accessControl;
    CapToken capToken;
    DebtToken debtToken;
    Delegation delegation;
    FeeAuction feeAuction;
    Lender lender;
    MockAaveDataProvider mockAaveDataProvider;
    MockChainlinkPriceFeed mockChainlinkPriceFeed;
    MockNetworkMiddleware mockNetworkMiddleware;
    Oracle oracle;
    StakedCap stakedCap;

    /// === GHOSTS === ///
    uint256 ghostAmountIn;
    uint256 ghostAmountOut;

    address agent = address(0xb0b);

    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.users.deployer = address(this);
        env.users.delegation_admin = address(this);
        env.users.oracle_admin = address(this);
        env.users.lender_admin = address(this);
        env.users.fee_auction_admin = address(this);
        env.users.access_control_admin = address(this);
        env.users.address_provider_admin = address(this);
        env.users.rate_oracle_admin = address(this);
        env.users.vault_config_admin = address(this);
        env.users.middleware_admin = address(this);
        env.users.staker_rewards_admin = address(this);
        env.users.insurance_fund = address(0xbeef); // insuranceFund needs to be set to a non-actor address to not mess up properties

        env.infra = _deployInfra(env.implems, env.users, 1 days);

        accessControl = AccessControl(env.infra.accessControl);
        lender = Lender(env.infra.lender);
        delegation = Delegation(env.infra.delegation);
        oracle = Oracle(env.infra.oracle);

        address[] memory assets = new address[](3);
        assets[0] = _newAsset(6);
        assets[1] = _newAsset(8);
        assets[2] = _newAsset(18);
        env.usdMocks = assets;

        /// Deploy mocks
        env.usdOracleMocks = OracleMocksConfig({
            assets: assets,
            aaveDataProviders: new address[](assets.length),
            chainlinkPriceFeeds: new address[](assets.length)
        });

        for (uint256 i = 0; i < assets.length; i++) {
            env.usdOracleMocks.aaveDataProviders[i] = address(new MockAaveDataProvider());
            env.usdOracleMocks.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed(1e8));
        }
        mockAaveDataProvider = MockAaveDataProvider(env.usdOracleMocks.aaveDataProviders[0]);
        mockChainlinkPriceFeed = MockChainlinkPriceFeed(env.usdOracleMocks.chainlinkPriceFeeds[0]);

        env.usdVault = _deployVault(env.implems, env.infra, "Cap USD", "cUSD", assets, env.users.insurance_fund);

        capToken = CapToken(env.usdVault.capToken);
        stakedCap = StakedCap(env.usdVault.stakedCapToken);
        feeAuction = FeeAuction(env.usdVault.feeAuction);

        /// ACCESS CONTROL
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.usdVault, env.users);

        /// ORACLE
        _initVaultOracle(env.libs, env.infra, env.usdVault);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            address asset = env.usdVault.assets[i];
            address chainlinkPriceFeed = env.usdOracleMocks.chainlinkPriceFeeds[i];
            address aavePriceFeed = env.usdOracleMocks.aaveDataProviders[i];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, chainlinkPriceFeed);
            _initAaveRateOracle(env.libs, env.infra, asset, aavePriceFeed);
        }
        //  oracle.setRestakerRate(address(this), uint256(1.585e18 + 0.01585e18));

        /// LENDER
        FeeConfig memory fee = FeeConfig({
            minMintFee: 0.005e27, // 0.5% minimum mint fee
            slope0: 0, // allow liquidity to be added without fee
            slope1: 0, // allow liquidity to be added without fee to start with
            mintKinkRatio: 0.85e27,
            burnKinkRatio: 0.15e27,
            optimalRatio: 0.33e27
        });
        _initVaultLender(env.usdVault, env.infra, fee);
        mockNetworkMiddleware = new MockNetworkMiddleware();
        delegation.registerNetwork(address(mockNetworkMiddleware));
        mockNetworkMiddleware.setMockCoverage(address(this), 1_000_000e8);
        mockNetworkMiddleware.setMockSlashableCollateral(address(this), 1_000_000e8);

        /// SETUP ACTORS
        _addActor(agent); // acts as user and agent
        address[] memory approvalArray = new address[](3);
        approvalArray[0] = address(capToken);
        approvalArray[1] = address(feeAuction);
        approvalArray[2] = address(lender);
        for (uint i; i < 3; i++) {
            _switchAsset(i);
            _finalizeAssetDeployment(_getActors(), approvalArray, type(uint88).max);
        }

        for (uint i; i < _getActors().length; i++) {
            vm.prank(_getActors()[i]);
            capToken.approve(address(feeAuction), type(uint88).max);
        }

        /// AGENT SETUP
        delegation.addAgent(agent, address(mockNetworkMiddleware), 0.5e27, 0.7e27);
        mockNetworkMiddleware.setMockSlashableCollateral(agent, 1e20);
        mockNetworkMiddleware.setMockCoverage(agent, 1e20);
        // @audit info: min(slashableCollateral, coverage) is needed for agent to be able to borrow

        _addLabels();

        // help fuzzer to reach to next epoch of vault
        vm.warp(block.timestamp + 1 days);
    }

    /// === INTERNAL FUNCTIONS === ///
    function _addLabels() internal {
        vm.label(address(accessControl), "AccessControl");
        vm.label(address(delegation), "Delegation");
        vm.label(address(oracle), "Oracle");
        vm.label(address(lender), "Lender");
        vm.label(address(capToken), "Vault(CapToken)");
        vm.label(address(stakedCap), "StakedCap");
        vm.label(address(feeAuction), "FeeAuction");
    }

    /// Copied from ConfigureAccessControl.sol to avoid circular dependency
    function _initInfraAccessControl(InfraConfig memory infra, UsersConfig memory users) internal {
        accessControl.grantAccess(IPriceOracle.setPriceOracleData.selector, infra.oracle, users.oracle_admin);
        accessControl.revokeAccess(IPriceOracle.setPriceOracleData.selector, infra.oracle, users.oracle_admin);
        accessControl.grantAccess(IPriceOracle.setPriceOracleData.selector, infra.oracle, users.oracle_admin);
        accessControl.grantAccess(IPriceOracle.setPriceBackupOracleData.selector, infra.oracle, users.oracle_admin);
        accessControl.grantAccess(bytes4(0), infra.oracle, users.access_control_admin);

        accessControl.grantAccess(IRateOracle.setBenchmarkRate.selector, infra.oracle, users.rate_oracle_admin);
        accessControl.grantAccess(IRateOracle.setRestakerRate.selector, infra.oracle, users.rate_oracle_admin);
        accessControl.grantAccess(IRateOracle.setMarketOracleData.selector, infra.oracle, users.rate_oracle_admin);
        accessControl.grantAccess(IRateOracle.setUtilizationOracleData.selector, infra.oracle, users.rate_oracle_admin);

        accessControl.grantAccess(Lender.addAsset.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.setMinBorrow.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.removeAsset.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.pauseAsset.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(bytes4(0), infra.lender, users.access_control_admin);

        accessControl.grantAccess(Lender.borrow.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.repay.selector, infra.lender, users.lender_admin);

        accessControl.grantAccess(Lender.liquidate.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.pauseAsset.selector, infra.lender, users.lender_admin);

        accessControl.grantAccess(Delegation.addAgent.selector, infra.delegation, users.delegation_admin);
        accessControl.grantAccess(Delegation.modifyAgent.selector, infra.delegation, users.delegation_admin);
        accessControl.grantAccess(Delegation.registerNetwork.selector, infra.delegation, users.delegation_admin);
        accessControl.grantAccess(Delegation.setLastBorrow.selector, infra.delegation, infra.lender);
        accessControl.grantAccess(Delegation.slash.selector, infra.delegation, infra.lender);
        accessControl.grantAccess(Delegation.setLtvBuffer.selector, infra.delegation, users.delegation_admin);
        accessControl.grantAccess(bytes4(0), infra.delegation, users.access_control_admin);
    }

    /// === MODIFIERS === ///
    /// Prank admin and actor

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
        vm.prank(address(_getActor()));
        _;
    }

    modifier asAgent() {
        vm.prank(agent);
        _;
    }
}
