// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";

contract LenderLiquidateTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        user_agent = env.testUsers.agents[0];
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
