// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { console } from "forge-std/console.sol";

contract LenderLiquidateTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env);

        user_agent = _getRandomAgent();

        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, user_agent, 2e18);
        _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, user_agent, 1000e6);
        vm.stopPrank();
    }

    function test_lender_liquidate_in_case_coverage_is_equal_to_debt() public {
        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(address(usdc), 3000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 3000e6);

            vm.stopPrank();
        }

        // Modify the agent to have 0.01 liquidation threshold
        {
            vm.startPrank(env.users.delegation_admin);
            Delegation(env.infra.delegation).modifyAgent(user_agent, 0.5e27, 0.01e27);
            vm.stopPrank();
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 1000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 3000e6);

            // start the first liquidation
            lender.initiateLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);
            // approve repay amount for liquidation
            usdc.approve(address(lender), 3000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");

            // start the second liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            // start the third liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after third liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after third liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            console.log("Liquidator usdc balance after third liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("");

            assertEq(usdc.balanceOf(env.testUsers.liquidator), 0);
            assertEq(usdt.balanceOf(env.testUsers.liquidator), 1000e6);
            assertEq(weth.balanceOf(env.testUsers.liquidator), 2e18);

            uint256 coverage = Delegation(env.infra.delegation).coverage(user_agent);
            console.log("Coverage after liquidations", coverage);
            console.log("");
            assertEq(coverage, 0);

            (uint256 totalDelegation, uint256 totalDebt,,,) = lender.agent(user_agent);

            assertEq(totalDelegation, 0);
            assertEq(totalDebt, 0);

            vm.stopPrank();
        }
    }

    function test_lender_liquidate_to_health_is_less_than_liquidation_threshold() public {
        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(address(usdc), 3000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 3000e6);

            vm.stopPrank();
        }

        // Modify the agent to have 0.01 liquidation threshold
        {
            vm.startPrank(env.users.delegation_admin);
            Delegation(env.infra.delegation).modifyAgent(user_agent, 0.5e27, 0.01e27);
            vm.stopPrank();
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 2000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 3000e6);

            // start the first liquidation
            lender.initiateLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);
            // approve repay amount for liquidation
            usdc.approve(address(lender), 3000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");

            // start the second liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            // start the third liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after third liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after third liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            console.log("Liquidator usdc balance after third liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("");

            //    assertEq(usdc.balanceOf(env.testUsers.liquidator), 0);
            //    assertEq(usdt.balanceOf(env.testUsers.liquidator), 1000e6);
            //    assertEq(weth.balanceOf(env.testUsers.liquidator), 2e18);

            uint256 coverage = Delegation(env.infra.delegation).coverage(user_agent);
            console.log("Coverage after liquidations", coverage);
            console.log("");
            //     assertEq(coverage, 0);

            (uint256 totalDelegation, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health) =
                lender.agent(user_agent);

            console.log("Health after liquidations", health);
            assertGt(health, 1e27);
            //    assertEq(totalDelegation, 0);
            //    assertEq(totalDebt, 0);

            vm.stopPrank();
        }
    }

    function test_lender_liquidate_in_the_future() public {
        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(address(usdc), 3000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 3000e6);

            /// well past all epochs
            _timeTravel(60 days);

            vm.stopPrank();
        }

        // Modify the agent to have 0.01 liquidation threshold
        {
            vm.startPrank(env.users.delegation_admin);
            Delegation(env.infra.delegation).modifyAgent(user_agent, 0.5e27, 0.01e27);
            vm.stopPrank();
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 2000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 3000e6);

            // start the first liquidation
            lender.initiateLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);
            // approve repay amount for liquidation
            usdc.approve(address(lender), 3000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");

            // start the second liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            // start the third liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6);

            console.log("Liquidator usdt balance after third liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after third liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            console.log("Liquidator usdc balance after third liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("");

            //    assertEq(usdc.balanceOf(env.testUsers.liquidator), 0);
            //    assertEq(usdt.balanceOf(env.testUsers.liquidator), 1000e6);
            //    assertEq(weth.balanceOf(env.testUsers.liquidator), 2e18);

            uint256 coverage = Delegation(env.infra.delegation).coverage(user_agent);
            console.log("Coverage after liquidations", coverage);
            console.log("");
            //     assertEq(coverage, 0);

            (uint256 totalDelegation, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health) =
                lender.agent(user_agent);

            console.log("Health after liquidations", health);
            assertGt(health, 1e27);
            //    assertEq(totalDelegation, 0);
            //    assertEq(totalDebt, 0);

            vm.stopPrank();
        }
    }
}
