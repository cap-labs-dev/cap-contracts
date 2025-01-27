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

contract LenderLiquidateTest is Test, TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        user_agent = env.testUsers.agent;
    }

    function test_lender_liquidate() public {
        // borrow some assets
        {
            vm.startPrank(user_agent);
            Lender(env.infra.lender).borrow(address(usdc), 1000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 1000e6);
            vm.stopPrank();
        }

        // simulate a price drop
        {
            vm.startPrank(env.users.oracle_admin);
            for (uint256 i = 0; i < env.oracleMocks.chainlinkPriceFeeds.length; i++) {
                MockChainlinkPriceFeed(env.oracleMocks.chainlinkPriceFeeds[i]).setLatestAnswer(1e1);
            }
            vm.stopPrank();
        }

        // anyone can liquidate the debt
        // {
        //     vm.startPrank(env.testUsers.liquidator);
        //     // approve repay amount for liquidation
        //     usdc.approve(address(lender), 1000e6);
        //     uint256 liquidatedAmount = lender.liquidate(env.testUsers.agent, address(usdc), 1000e6);
        //     assertEq(liquidatedAmount, 100000e18);
        //     vm.stopPrank();
        // }
    }
}
