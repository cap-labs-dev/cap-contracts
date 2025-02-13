// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { console } from "forge-std/console.sol";

contract LenderLiquidateTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        _initSymbioticVaultsLiquidity(env);

        user_agent = env.testUsers.agents[0];
    }

    function test_lender_liquidate() public {
        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(address(usdc), 1000000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 1000000e6);

            vm.stopPrank();
        }

        // simulate a price drop
        {
            vm.startPrank(env.users.delegation_admin);
            Delegation(env.infra.delegation).modifyAgent(user_agent, 0.5e27, 0.01e27);
            vm.stopPrank();
        }

        // change eth oracle price
        {
            vm.startPrank(env.users.oracle_admin);
            MockChainlinkPriceFeed(env.oracleMocks.chainlinkPriceFeeds[env.oracleMocks.assets.length]).setLatestAnswer(10e8);
            vm.stopPrank();
        }

        (uint256 totalDelegation, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health) = lender.agent(user_agent);
        console.log("totalDelegation", totalDelegation);
        console.log("totalDebt", totalDebt);
        console.log("ltv", ltv);
        console.log("liquidationThreshold", liquidationThreshold);
        console.log("health", health);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 1000e6);

            lender.initiateLiquidation(user_agent);

            uint256 gracePeriod = lender.grace();

            uint256 balanceBefore = weth.balanceOf(env.testUsers.liquidator);
            console.log("balanceBefore", balanceBefore);

            _timeTravel(gracePeriod + 1);
            // approve repay amount for liquidation
            usdc.approve(address(lender), 1000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6);
            console.log("liquidatedAmountUsdt", usdc.balanceOf(env.testUsers.liquidator));
            console.log("liquidatedAmountEth", weth.balanceOf(env.testUsers.liquidator) / 1e18);

            // assertEq(liquidatedAmount, 100000e18);
            vm.stopPrank();
        }
    }
}
