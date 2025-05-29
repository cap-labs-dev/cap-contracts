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
import "contracts/access/AccessControl.sol";

import "contracts/delegation/Delegation.sol";

import { FeeConfig } from "contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "contracts/deploy/service/ConfigureAccessControl.sol";
import { ConfigureDelegation } from "contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "contracts/deploy/service/DeployVault.sol";
import "contracts/feeAuction/FeeAuction.sol";
import "contracts/lendingPool/Lender.sol";
import "contracts/lendingPool/tokens/DebtToken.sol";

import "contracts/oracle/Oracle.sol";
import "contracts/token/CapToken.sol";
import "contracts/token/StakedCap.sol";
import { TestEnvConfig } from "test/deploy/interfaces/TestDeployConfig.sol";
import "test/mocks/MockAaveDataProvider.sol";
import "test/mocks/MockChainlinkPriceFeed.sol";
import "test/mocks/MockNetworkMiddleware.sol";

abstract contract Setup is
    BaseSetup,
    ActorManager,
    AssetManager,
    Utils,
    DeployInfra,
    DeployVault,
    DeployImplems,
    DeployLibs,
    ConfigureOracle,
    ConfigureDelegation,
    ConfigureAccessControl
{
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
        env.users.insurance_fund = address(this);

        env.infra = _deployInfra(env.implems, env.users, 1 days);

        accessControl = AccessControl(env.infra.accessControl);
        lender = Lender(env.infra.lender);
        delegation = Delegation(env.infra.delegation);
        oracle = Oracle(env.infra.oracle);

        address[] memory assets = new address[](1);
        assets[0] = _newAsset(6);

        mockAaveDataProvider = new MockAaveDataProvider();
        mockChainlinkPriceFeed = new MockChainlinkPriceFeed(1e8);

        env.usdVault = _deployVault(env.implems, env.infra, "Cap USD", "cUSD", assets, env.users.insurance_fund);

        capToken = CapToken(env.usdVault.capToken);
        stakedCap = StakedCap(env.usdVault.stakedCapToken);
        debtToken = DebtToken(env.usdVault.debtTokens[0]);
        feeAuction = FeeAuction(env.usdVault.feeAuction);

        /// ACCESS CONTROL
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.usdVault, env.users);

        /// ORACLE
        _initVaultOracle(env.libs, env.infra, env.usdVault);
        _initChainlinkPriceOracle(env.libs, env.infra, assets[0], address(mockChainlinkPriceFeed));
        _initAaveRateOracle(env.libs, env.infra, assets[0], address(mockAaveDataProvider));
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
        // delegation.addAgent(address(this), address(mockNetworkMiddleware), 0.5e27, 0.7e27);
        mockNetworkMiddleware.setMockCoverage(address(this), 1_000_000e8);
        mockNetworkMiddleware.setMockSlashableCollateral(address(this), 1_000_000e8);
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
}
