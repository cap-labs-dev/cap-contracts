// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";

import { IStrategy } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { ValidationLogic } from "../../contracts/lendingPool/libraries/ValidationLogic.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract LenderLiquidateTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault, 10000e18);
        _initSymbioticVaultsLiquidity(env, 100);

        _timeTravel(5 days);

        user_agent = _getRandomAgent();

        vm.startPrank(env.users.lender_admin);
        // Try removing and re-adding the asset
        lender.removeAsset(address(usdt));

        vm.expectRevert();
        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(0),
                vault: address(cUSD),
                debtToken: env.usdVault.debtTokens[0],
                interestReceiver: env.usdVault.feeAuction,
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        vm.expectRevert();
        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(usdt),
                vault: address(0),
                debtToken: env.usdVault.debtTokens[0],
                interestReceiver: env.usdVault.feeAuction,
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        vm.expectRevert();
        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(usdt),
                vault: address(cUSD),
                debtToken: address(0),
                interestReceiver: env.usdVault.feeAuction,
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        vm.expectRevert();
        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(usdt),
                vault: address(cUSD),
                debtToken: env.usdVault.debtTokens[0],
                interestReceiver: address(0),
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        vm.expectRevert();
        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(usdt),
                vault: address(cUSD),
                debtToken: address(0),
                interestReceiver: env.usdVault.feeAuction,
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        lender.addAsset(
            ILender.AddAssetParams({
                asset: address(usdt),
                vault: address(cUSD),
                debtToken: env.usdVault.debtTokens[0],
                interestReceiver: env.usdVault.feeAuction,
                bonusCap: 0.1e27,
                minBorrow: 100e6
            })
        );

        uint256 reservesCount = lender.reservesCount();
        console.log("Reserves Count", reservesCount);

        vm.expectRevert();
        lender.pauseAsset(address(0), false);

        lender.pauseAsset(address(usdt), false);
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

        vm.startPrank(env.testUsers.liquidator);

        vm.expectRevert();
        lender.openLiquidation(user_agent);

        _timeTravel(5 days);

        vm.stopPrank();

        // Modify the agent to have 0.01 liquidation threshold
        {
            _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 1000e18, true);
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 1000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            uint256 assetIndex = _getAssetIndex(usdVault, address(usdc));
            DebtToken debtToken = DebtToken(usdVault.debtTokens[assetIndex]);

            // start the first liquidation
            lender.openLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);

            console.log("grace period", gracePeriod + 1);
            console.log("delegation epoch duration", delegation.epochDuration());

            vm.expectRevert();
            lender.maxLiquidatable(address(0), address(usdc));

            vm.expectRevert();
            lender.maxLiquidatable(user_agent, address(0));

            vm.expectRevert();
            lender.liquidate(address(0), address(usdc), 1000e6, 0);

            vm.expectRevert();
            lender.liquidate(user_agent, address(0), 1000e6, 0);

            uint256 emergencyLiquidationThreshold = lender.emergencyLiquidationThreshold();
            console.log("Emergency Liquidation Threshold", emergencyLiquidationThreshold);

            uint256 bonusCap = lender.bonusCap();
            console.log("Bonus Cap", bonusCap);

            uint256 targetHealth = lender.targetHealth();
            console.log("Target Health", targetHealth);

            deal(address(usdc), env.testUsers.liquidator, 1000e6);
            // approve repay amount for liquidation
            usdc.approve(address(lender), type(uint256).max);

            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            (,, uint256 totalDebt,,,) = lender.agent(user_agent);
            console.log("Debt prior to liquidation", totalDebt);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator usdc balance after first liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after first liquidation", debtToken.balanceOf(user_agent));
            console.log("");

            // start the second liquidation
            deal(address(usdc), env.testUsers.liquidator, 1000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator usdc balance after second liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after second liquidation", debtToken.balanceOf(user_agent));
            console.log("");
            // start the third liquidation
            deal(address(usdc), env.testUsers.liquidator, debtToken.balanceOf(user_agent));
            lender.liquidate(user_agent, address(usdc), debtToken.balanceOf(user_agent), 0);

            console.log("Liquidator usdt balance after third liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after third liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            console.log("Liquidator usdc balance after third liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after third liquidation", debtToken.balanceOf(user_agent));
            console.log("");

            (uint256 totalDelegation,, uint256 afterTotalDebt,,, uint256 health) = lender.agent(user_agent);
            console.log("Health after liquidations", health);

            assertEq(usdc.balanceOf(env.testUsers.liquidator), 0);
            assertGt(weth.balanceOf(env.testUsers.liquidator), 0);

            uint256 coverage = Delegation(env.infra.delegation).coverage(user_agent);
            console.log("Coverage after liquidations", coverage);
            console.log("");
            assertEq(coverage, 0);

            // (uint256 totalDelegation,, uint256 afterTotalDebt,,,) = lender.agent(user_agent);

            console.log("Total delegation", totalDelegation);
            console.log("Total debt before liquidation", totalDebt);
            console.log("Total debt", afterTotalDebt);
            assertEq(totalDelegation, 0);

            /// We fully liquidated the debt
            assertEq(afterTotalDebt, 0);

            vm.stopPrank();
        }
    }

    function test_lender_liquidate_in_case_coverage_is_equal_to_debt_eigen() public {
        user_agent = _getAgent(1);
        IERC20 collateralToken = IERC20(IStrategy(eigenAb.eigenAddresses.strategy).underlyingToken());
        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(address(usdc), 3000e6, user_agent);
            assertEq(usdc.balanceOf(user_agent), 3000e6);

            vm.stopPrank();
        }

        vm.startPrank(env.testUsers.liquidator);

        vm.expectRevert();
        lender.openLiquidation(user_agent);

        _timeTravel(5 days);

        vm.stopPrank();

        // Modify the agent to have 0.01 liquidation threshold
        {
            _proportionallyWithdrawFromStrategy(
                eigenAb, env.testUsers.restakers[1], eigenAb.eigenAddresses.strategy, 100, true
            );
        }

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            uint256 assetIndex = _getAssetIndex(usdVault, address(usdc));
            DebtToken debtToken = DebtToken(usdVault.debtTokens[assetIndex]);

            // start the first liquidation
            lender.openLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);

            console.log("grace period", gracePeriod + 1);
            console.log("delegation epoch duration", delegation.epochDuration());

            vm.expectRevert();
            lender.maxLiquidatable(address(0), address(usdc));

            vm.expectRevert();
            lender.maxLiquidatable(user_agent, address(0));

            vm.expectRevert();
            lender.liquidate(address(0), address(usdc), 1000e6, 0);

            vm.expectRevert();
            lender.liquidate(user_agent, address(0), 1000e6, 0);

            uint256 emergencyLiquidationThreshold = lender.emergencyLiquidationThreshold();
            console.log("Emergency Liquidation Threshold", emergencyLiquidationThreshold);

            uint256 bonusCap = lender.bonusCap();
            console.log("Bonus Cap", bonusCap);

            uint256 targetHealth = lender.targetHealth();
            console.log("Target Health", targetHealth);

            deal(address(usdc), env.testUsers.liquidator, 1000e6);
            // approve repay amount for liquidation
            usdc.approve(address(lender), type(uint256).max);

            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            (,, uint256 totalDebt,,,) = lender.agent(user_agent);
            console.log("Debt prior to liquidation", totalDebt);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log(
                "Liquidator collateral balance after first liquidation",
                collateralToken.balanceOf(env.testUsers.liquidator)
            );
            console.log("Liquidator usdc balance after first liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after first liquidation", debtToken.balanceOf(user_agent));
            console.log("");

            // start the second liquidation
            deal(address(usdc), env.testUsers.liquidator, 1000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log(
                "Liquidator collateral balance after second liquidation",
                collateralToken.balanceOf(env.testUsers.liquidator)
            );
            console.log("Liquidator usdc balance after second liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after second liquidation", debtToken.balanceOf(user_agent));
            console.log("");
            // start the third liquidation
            deal(address(usdc), env.testUsers.liquidator, debtToken.balanceOf(user_agent));
            lender.liquidate(user_agent, address(usdc), debtToken.balanceOf(user_agent), 0);

            console.log("Liquidator usdt balance after third liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log(
                "Liquidator collateral balance after third liquidation",
                collateralToken.balanceOf(env.testUsers.liquidator)
            );
            console.log("");
            console.log("Liquidator usdc balance after third liquidation", usdc.balanceOf(env.testUsers.liquidator));
            console.log("User debt tokens after third liquidation", debtToken.balanceOf(user_agent));
            console.log("");

            (uint256 totalDelegation,, uint256 afterTotalDebt,,, uint256 health) = lender.agent(user_agent);
            console.log("Health after liquidations", health);

            assertEq(usdc.balanceOf(env.testUsers.liquidator), 0);
            assertGt(collateralToken.balanceOf(env.testUsers.liquidator), 0);

            uint256 coverage = Delegation(env.infra.delegation).coverage(user_agent);
            console.log("Coverage after liquidations", coverage);
            console.log("");
            assertEq(coverage, 0);

            // (uint256 totalDelegation,, uint256 afterTotalDebt,,,) = lender.agent(user_agent);

            console.log("Total delegation", totalDelegation);
            console.log("Total debt before liquidation", totalDebt);
            console.log("Total debt", afterTotalDebt);
            assertEq(totalDelegation, 0);

            /// We fully liquidated the debt
            assertEq(afterTotalDebt, 0);

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

        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 3000e6);

            usdc.approve(address(lender), 1000e6);

            vm.expectRevert();
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);
            vm.stopPrank();
        }

        // Modify the agent to have 0.01 liquidation threshold
        {
            _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 99.5e18, false);
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 2000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            deal(address(usdc), env.testUsers.liquidator, 3000e6);

            // start the first liquidation
            lender.openLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();
            uint256 expiry = lender.expiry();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);
            // approve repay amount for liquidation
            usdc.approve(address(lender), 3000e6);
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");

            _timeTravel(expiry + 1);

            // start the second liquidation
            /* vm.expectRevert(ValidationLogic.LiquidationExpired.selector);
            lender.liquidate(user_agent, address(usdc), 1000e6);*/

            /*lender.openLiquidation(user_agent);

            _timeTravel(gracePeriod + 1);

            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            /*
            _setAssetOraclePrice(address(weth), 1035e8);

            // start the third liquidation

            _timeTravel(expiry + 1);

            vm.startPrank(env.testUsers.liquidator);

            lender.openLiquidation(user_agent);
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
            */

            (uint256 totalDelegation,, uint256 totalDebt,,, uint256 health) = lender.agent(user_agent);

            console.log("Total debt after liquidations", totalDebt);
            console.log("Total delegation after liquidations", totalDelegation);
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
            _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 1000e18, true);
        }

        // change eth oracle price
        _setAssetOraclePrice(address(weth), 2000e8);

        // anyone can liquidate the debt
        {
            vm.startPrank(env.testUsers.liquidator);

            // dealing a bit more since now we cover the interest
            deal(address(usdc), env.testUsers.liquidator, 3200e6);

            // start the first liquidation
            lender.openLiquidation(user_agent);
            uint256 gracePeriod = lender.grace();

            console.log("Starting Liquidations");
            console.log("");
            _timeTravel(gracePeriod + 1);

            (uint256 totalDelegation,, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health) =
                lender.agent(user_agent);

            console.log("Total debt after 60 days", totalDebt);
            console.log("Total delegation after 60 days", totalDelegation);
            console.log("LTV after 60 days", ltv);
            console.log("Liquidation threshold after 60 days", liquidationThreshold);
            console.log("Health after 60 days", health);

            // approve repay amount for liquidation
            usdc.approve(address(lender), 3200e6);
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after first liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after first liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");

            // start the second liquidation
            lender.liquidate(user_agent, address(usdc), 1000e6, 0);

            console.log("Liquidator usdt balance after second liquidation", usdt.balanceOf(env.testUsers.liquidator));
            console.log("Liquidator weth balance after second liquidation", weth.balanceOf(env.testUsers.liquidator));
            console.log("");
            // start the third liquidation
            lender.liquidate(user_agent, address(usdc), 1200e6, 0);

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

            (totalDelegation,, totalDebt, ltv, liquidationThreshold, health) = lender.agent(user_agent);

            console.log("Health after liquidations", health);

            console.log("Total debt after liquidations", totalDebt);
            console.log("Total delegation after liquidations", totalDelegation);
            assertGt(health, 1e27);
            //    assertEq(totalDelegation, 0);
            //    assertEq(totalDebt, 0);

            vm.stopPrank();
        }
    }

    function test_agent_evade_slash() public {
        vm.startPrank(user_agent);
        console.log("block.timestamp", block.timestamp);
        lender.borrow(address(usdc), type(uint256).max, user_agent);
        vm.stopPrank();

        _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 1000e18, true);

        _timeTravel(1);

        uint256 slashableCollateral = delegation.slashableCollateral(user_agent);
        (,, uint256 totalDebt,,,) = lender.agent(user_agent);
        assertGt(slashableCollateral, totalDebt);
    }
}
