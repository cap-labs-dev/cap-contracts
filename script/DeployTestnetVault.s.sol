// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    FeeConfig,
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig,
    VaultConfig
} from "../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureDelegation } from "../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "../contracts/deploy/service/ConfigureOracle.sol";
import { DeployVault } from "../contracts/deploy/service/DeployVault.sol";
import { LzAddressbook, LzUtils } from "../contracts/deploy/utils/LzUtils.sol";
import { ZapAddressbook, ZapUtils } from "../contracts/deploy/utils/ZapUtils.sol";
import { OracleMocksConfig } from "../test/deploy/interfaces/TestDeployConfig.sol";
import { DeployMocks } from "../test/deploy/service/DeployMocks.sol";
import { InitTestVaultLiquidity } from "../test/deploy/service/InitTestVaultLiquidity.sol";
import { InfraConfigSerializer } from "./config/InfraConfigSerializer.sol";
import { VaultConfigSerializer } from "./config/VaultConfigSerializer.sol";
import { WalletUsersConfig } from "./config/WalletUsersConfig.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

contract DeployTestnetVault is
    Script,
    WalletUsersConfig,
    InfraConfigSerializer,
    VaultConfigSerializer,
    LzUtils,
    ZapUtils,
    DeployMocks,
    DeployVault,
    ConfigureOracle,
    InitTestVaultLiquidity
{
    LzAddressbook lzAb;
    ZapAddressbook zapAb;

    UsersConfig users;
    InfraConfig infra;
    ImplementationsConfig implems;
    LibsConfig libs;
    address[] assetMocks;
    OracleMocksConfig oracleMocks;
    VaultConfig vault;

    function run() external {
        vm.startBroadcast();

        users = _getUsersConfig();
        lzAb = _getLzAddressbook();
        zapAb = _getZapAddressbook();
        (implems, libs, infra) = _readInfraConfig();

        assetMocks = _deployUSDMocks();
        oracleMocks = _deployOracleMocks(assetMocks);

        vault = _deployVault(implems, infra, "cap USD", "cUSD", oracleMocks.assets, users.insurance_fund);
        vault.lzperiphery = _deployVaultLzPeriphery(lzAb, zapAb, vault, users);

        /// ACCESS CONTROL
        _initVaultAccessControl(infra, vault, users);

        /// VAULT ORACLE
        _initOracleMocks(oracleMocks, 1e8, uint256(0.1e27));
        _initVaultOracle(libs, infra, vault);
        for (uint256 i = 0; i < oracleMocks.assets.length; i++) {
            address asset = oracleMocks.assets[i];
            address priceFeed = oracleMocks.chainlinkPriceFeeds[i];
            address aaveDataProvider = oracleMocks.aaveDataProviders[i];
            _initChainlinkPriceOracle(libs, infra, asset, priceFeed);
            _initAaveRateOracle(libs, infra, asset, aaveDataProvider);
        }

        FeeConfig memory fee = FeeConfig({
            minMintFee: 0.005e27, // 0.5% minimum mint fee
            slope0: 0, // allow liquidity to be added without fee
            slope1: 0, // allow liquidity to be added without fee to start with
            mintKinkRatio: 0.85e27,
            burnKinkRatio: 0.15e27,
            optimalRatio: 0.33e27
        });

        /// LENDER
        _initVaultLender(vault, infra, fee);

        _saveVaultConfig(vault);

        // deposit into vault
        for (uint256 i = 0; i < vault.assets.length; i++) {
            address asset = vault.assets[i];
            address sendTo = getWalletAddress();
            uint256 amount = 10_000 * 10 ** IERC20Metadata(asset).decimals();
            _initTestUserMintCapToken(vault, asset, sendTo, amount);
            _initTestUserMintStakedCapToken(vault, asset, sendTo, amount);
        }

        vm.stopBroadcast();
    }
}
