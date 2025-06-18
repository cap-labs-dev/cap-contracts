// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseSetup } from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";

// Managers
import { ActorManager } from "@recon/ActorManager.sol";
import { AssetManager } from "@recon/AssetManager.sol";

// Helpers

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { MockERC20 } from "@recon/MockERC20.sol";
import { Utils } from "@recon/Utils.sol";

// Your deps
import { AccessControl } from "contracts/access/AccessControl.sol";
import { Delegation } from "contracts/delegation/Delegation.sol";
import { FeeConfig, InfraConfig, UsersConfig } from "contracts/deploy/interfaces/DeployConfigs.sol";
import { Minter } from "contracts/vault/Minter.sol";
import { Vault } from "contracts/vault/Vault.sol";

import { ConfigureAccessControl } from "contracts/deploy/service/ConfigureAccessControl.sol";
import { ConfigureDelegation } from "contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "contracts/deploy/service/DeployVault.sol";
import { FeeAuction } from "contracts/feeAuction/FeeAuction.sol";
import { FeeReceiver } from "contracts/feeReceiver/FeeReceiver.sol";

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
import { MockMiddleware } from "test/recon/mocks/MockMiddleware.sol";

import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";
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
    ConfigureAccessControl,
    ConfigureDelegation
{
    // ConfigureAccessControl

    TestEnvConfig env;

    AccessControl accessControl;
    CapToken capToken;
    DebtToken debtToken;
    Delegation delegation;
    FeeAuction feeAuction;
    FeeReceiver feeReceiver;
    LenderWrapper lender;
    MockAaveDataProvider mockAaveDataProvider;
    MockChainlinkPriceFeed mockChainlinkPriceFeed;
    MockMiddleware mockNetworkMiddleware;
    Oracle oracle;
    StakedCap stakedCap;

    /// === GHOSTS === ///
    uint256 ghostAmountIn;
    uint256 ghostAmountOut;

    address mockEth;
    int256 maxAmountOut;
    int256 maxDebtDifference;

    uint256 constant RAY = 1e27;

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
            aaveDataProviders: new address[](assets.length + 1), // +1 for ETH
            chainlinkPriceFeeds: new address[](assets.length + 1) // +1 for ETH
         });

        for (uint256 i = 0; i < assets.length; i++) {
            env.usdOracleMocks.aaveDataProviders[i] = address(new MockAaveDataProvider());
            env.usdOracleMocks.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed(1e8));
        }
        // Add ETH oracle mocks
        mockEth = address(new MockERC20("Mock ETH", "mETH", 18));
        env.usdOracleMocks.aaveDataProviders[assets.length] = address(new MockAaveDataProvider());
        env.usdOracleMocks.chainlinkPriceFeeds[assets.length] = address(new MockChainlinkPriceFeed(2500e8));

        mockAaveDataProvider = MockAaveDataProvider(env.usdOracleMocks.aaveDataProviders[0]);
        mockChainlinkPriceFeed = MockChainlinkPriceFeed(env.usdOracleMocks.chainlinkPriceFeeds[0]);

        env.usdVault = _deployVault(env.implems, env.infra, "Cap USD", "cUSD", assets, env.users.insurance_fund);

        capToken = CapToken(env.usdVault.capToken);
        stakedCap = StakedCap(env.usdVault.stakedCapToken);
        feeAuction = FeeAuction(env.usdVault.feeAuction);
        feeReceiver = FeeReceiver(env.usdVault.feeReceiver);

        /// ACCESS CONTROL
        _initInfraAccessControl(env.infra, env.users);
        _initVaultAccessControl(env.infra, env.usdVault, env.users);
        accessControl.grantAccess(Vault.addAsset.selector, env.usdVault.capToken, env.users.vault_config_admin);
        accessControl.grantAccess(Vault.removeAsset.selector, env.usdVault.capToken, env.users.vault_config_admin);
        accessControl.grantAccess(Vault.rescueERC20.selector, env.usdVault.capToken, env.users.vault_config_admin);
        accessControl.grantAccess(Minter.setWhitelist.selector, env.usdVault.capToken, env.users.vault_config_admin);

        // Lets us use the additional getters in LenderWrapper for properties without having to change their existing deployment files
        address newLenderImplementation = address(new LenderWrapper());
        vm.prank(env.users.access_control_admin);
        Lender(env.infra.lender).upgradeToAndCall(newLenderImplementation, "");
        lender = LenderWrapper(env.infra.lender);

        /// ORACLE
        _initVaultOracle(env.libs, env.infra, env.usdVault);
        for (uint256 i = 0; i < env.usdVault.assets.length; i++) {
            address asset = env.usdVault.assets[i];
            address _chainlinkPriceFeed = env.usdOracleMocks.chainlinkPriceFeeds[i];
            address _aavePriceFeed = env.usdOracleMocks.aaveDataProviders[i];
            _initChainlinkPriceOracle(env.libs, env.infra, asset, _chainlinkPriceFeed);
            _initAaveRateOracle(env.libs, env.infra, asset, _aavePriceFeed);
        }
        _initChainlinkPriceOracle(env.libs, env.infra, mockEth, env.usdOracleMocks.chainlinkPriceFeeds[assets.length]); // Mock ETH
        _initAaveRateOracle(env.libs, env.infra, mockEth, env.usdOracleMocks.aaveDataProviders[assets.length]); // Mock ETH
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
        mockNetworkMiddleware = new MockMiddleware(address(oracle));
        mockNetworkMiddleware.registerVault(mockEth, address(stakedCap));
        delegation.registerNetwork(address(mockNetworkMiddleware));

        /// SETUP ACTORS
        _addActor(address(0x0001)); // acts as user and agent
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
            vm.prank(_getActors()[i]);
            MockERC20(mockEth).approve(address(mockNetworkMiddleware), type(uint88).max);

            /// AGENT SETUP
            delegation.addAgent(_getActors()[i], address(mockNetworkMiddleware), 0.5e27, 0.7e27);
            mockNetworkMiddleware.registerAgent(_getActors()[i], mockEth);
            mockNetworkMiddleware.setMockCollateralByVault(_getActors()[i], mockEth, 100e18); // @audit CLAMP - we provide initial collateral to network
                // @audit info: min(slashableCollateral, coverage) is needed for actor to be able to borrow
        }

        // help fuzzer to reach to next epoch of vault
        vm.warp(block.timestamp + 1 days);
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
