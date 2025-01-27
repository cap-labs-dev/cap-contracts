// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IStakedCap } from "../../contracts/interfaces/IStakedCap.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { VaultUpgradeable } from "../../contracts/vault/VaultUpgradeable.sol";

import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockDelegation } from "../mocks/MockDelegation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";

contract StakedCapWithdrawTest is Test, TestDeployer {
    address user;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);

        // unwrap some config to make the tests more readable
        vault = env.vault;
        usdt = MockERC20(vault.assets[0]);
        usdc = MockERC20(vault.assets[1]);
        usdx = MockERC20(vault.assets[2]);
        cUSD = CapToken(vault.capToken);
        scUSD = StakedCap(vault.stakedCapToken);

        user = makeAddr("test_user");
        _initTestUserStakedCapToken(env.vault, user, 4000e18);
    }

    function test_staked_cap_withdraw() public {
        vm.startPrank(user);

        uint256 outputAmount = scUSD.withdraw(100e18, user, user);

        assertEq(outputAmount, 100e18, "Should have received 100 cUSD");
        assertEq(scUSD.balanceOf(user), 4000e18 - 100e18, "Should have burned some scUSD tokens");
        assertEq(cUSD.balanceOf(user), 100e18, "Should have gained back their cUSD tokens");
    }
}
