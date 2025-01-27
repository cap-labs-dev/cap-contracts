// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UsersConfig, VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";

import { ConfigureAccessControl } from "../../contracts/deploy/service/ConfigureAccessControl.sol";
import { ConfigureDelegation } from "../../contracts/deploy/service/ConfigureDelegation.sol";
import { ConfigureOracle } from "../../contracts/deploy/service/ConfigureOracle.sol";
import { DeployImplems } from "../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "../../contracts/deploy/service/DeployLibs.sol";
import { DeployVault } from "../../contracts/deploy/service/DeployVault.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TestEnvConfig } from "./interfaces/TestDeployConfig.sol";
import { DeployMocks } from "./service/DeployTestMocks.sol";
import { DeployTestUsers } from "./service/DeployTestUsers.sol";
import { InitTestVaultLiquidity } from "./service/InitTestVaultLiquidity.sol";

import { Test, console } from "forge-std/Test.sol";

contract TestDeployer is
    Test,
    DeployMocks,
    DeployInfra,
    DeployVault,
    DeployImplems,
    DeployLibs,
    ConfigureOracle,
    ConfigureDelegation,
    ConfigureAccessControl,
    DeployTestUsers,
    InitTestVaultLiquidity
{
    TestEnvConfig env;
    VaultConfig vault;
    MockERC20 usdt;
    MockERC20 usdc;
    MockERC20 usdx;
    CapToken cUSD;
    StakedCap scUSD;

    function _deployCapTestEnvironment() internal {
        (env.users, env.testUsers) = _deployTestUsers();

        /// DEPLOY
        vm.startPrank(env.users.deployer);

        env.implems = _deployImplementations();
        env.libs = _deployLibs();
        env.infra = _deployInfra(env.implems, env.users);

        address[] memory assets = _deployUSDMocks();
        env.delegationMock = _deployDelegationMock(env.testUsers.agent);
        env.oracleMocks = _deployOracleMocks(assets);

        console.log("deploying vault");
        env.vault = _deployVault(env.implems, env.infra, "Cap USD", "cUSD", env.oracleMocks.assets);

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
        console.log("deploying rate oracle");
        vm.startPrank(env.users.rate_oracle_admin);
        for (uint256 i = 0; i < env.vault.assets.length; i++) {
            _initAaveRateOracle(env.libs, env.infra, env.vault.assets[i], env.oracleMocks.aaveDataProviders[i]);
        }

        /// LENDER
        console.log("deploying lender");
        vm.startPrank(env.users.lender_admin);
        _initVaultLender(env.vault, env.infra, env.users);

        /// DELEGATION
        console.log("deploying delegation");
        vm.startPrank(env.users.delegation_admin);
        _initDelegation(env.infra, env.testUsers.agent, env.delegationMock.delegators);

        // unwrap some config to make the tests more readable
        vault = env.vault;
        usdt = MockERC20(vault.assets[0]);
        usdc = MockERC20(vault.assets[1]);
        usdx = MockERC20(vault.assets[2]);
        cUSD = CapToken(vault.capToken);
        scUSD = StakedCap(vault.stakedCapToken);
    }
}
