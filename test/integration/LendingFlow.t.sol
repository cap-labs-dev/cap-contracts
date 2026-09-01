// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice End-to-end lending lifecycle: supply -> borrow -> accrue -> repay -> rewards -> liquidate.
contract LendingFlowTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal supplier0 = makeAddr("supplier0");
    address internal supplier1 = makeAddr("supplier1");
    address internal stranger = makeAddr("stranger");
    FloatingMarket internal market;
    address internal tranche0;
    address internal tranche1;

    uint256 internal constant TRANCHE1_DEPOSIT = 600e18;
    uint256 internal constant TRANCHE0_DEPOSIT = 400e18;

    function setUp() public {
        _deployCap();

        address marketAddr;
        (marketAddr, tranche0, tranche1) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);

        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );

        market.setMarketMultiplier(1e27);

        _fundTranche(tranche1, supplier1, TRANCHE1_DEPOSIT);
        _fundTranche(tranche0, supplier0, TRANCHE0_DEPOSIT);

        market.setFixedCreditLimit(1_000e18);
    }

    function test_availableCredit_isLtvOfCapital() public view {
        assertEq(market.availableCredit(), 500e18);
        assertEq(market.creditLimit(), 500e18);
        assertEq(market.debtLiquidationThreshold(), 800e18);
    }

    function test_borrow_mintsStableAndRecordsDebt() public {
        vm.prank(borrower);
        uint256 borrowed = market.borrow(borrower, 300e18);

        assertEq(borrowed, 300e18);
        assertEq(stablecoin.balanceOf(borrower), 300e18);
        assertApproxEqAbs(market.totalDebt(), 300e18, 1);
        assertApproxEqAbs(market.availableCredit(), 200e18, 1);
    }

    function test_borrow_unauthorizedCaller_reverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.borrow(stranger, 1e18);
    }

    function test_borrow_exceedingCredit_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.borrow(borrower, 500e18 + 1);
    }

    function test_borrow_maxUint_borrowsMaxBorrowable() public {
        vm.prank(borrower);
        uint256 borrowed = market.borrow(borrower, type(uint256).max);
        assertEq(borrowed, 500e18);
        assertEq(stablecoin.balanceOf(borrower), 500e18);
    }

    function test_interestAccruesOverTime() public {
        vm.prank(borrower);
        market.borrow(borrower, 300e18);
        uint256 debtBefore = market.totalDebt();

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = market.totalDebt();
        assertGt(debtAfter, debtBefore);
    }

    function test_repay_reducesDebtAndBurnsStable() public {
        vm.startPrank(borrower);
        market.borrow(borrower, 300e18);
        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = market.totalDebt();
        uint256 repaid = market.repay(100e18);
        vm.stopPrank();

        assertEq(repaid, 100e18);
        assertEq(stablecoin.balanceOf(borrower), 200e18);
        assertApproxEqAbs(market.totalDebt(), debtBefore - 100e18, 2);
    }

    function test_repay_capsAtOutstandingDebt() public {
        vm.startPrank(borrower);
        market.borrow(borrower, 100e18);
        uint256 repaid = market.repay(1_000e18);
        vm.stopPrank();

        assertApproxEqAbs(repaid, 100e18, 1);
        assertApproxEqAbs(market.totalDebt(), 0, 2);
    }

    function test_supplyReward_accruesToYieldRecipient() public {
        address stcUsd = makeAddr("stcUSD");
        market.setStakedStablecoin(stcUsd);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        market.repay(1);

        assertGt(stablecoin.balanceOf(stcUsd), 0);
    }

    function test_underwriterReward_accruesAndClaims() public {
        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        market.repay(1);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(supplier1);
        uint256 reward = Tranche(tranche1).claim(supplier1);
        assertGt(reward, 0);
        assertEq(stablecoin.balanceOf(supplier1), reward);
    }

    function test_liquidate_solventMarket_reverts() public {
        vm.prank(borrower);
        market.borrow(borrower, 100e18);

        vm.expectRevert(IBaseMarket.Healthy.selector);
        vm.prank(defaultLiquidator);
        market.liquidate(borrower, 50e18);
    }

    function test_liquidate_unhealthyMarket_repaysAndSlashes() public {
        vm.prank(borrower);
        market.borrow(borrower, 500e18);

        vm.warp(block.timestamp + 3650 days);
        assertGt(market.maxLiquidatable(), 0);

        uint256 recipientCollateralBefore = collateral.balanceOf(borrower);
        _mintStable(defaultLiquidator, 100e18);

        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(borrower, 100e18);

        assertGt(repaid, 0);
        assertGe(collateral.balanceOf(borrower), recipientCollateralBefore);
        assertLe(slashed, TRANCHE1_DEPOSIT + TRANCHE0_DEPOSIT);
    }

    function test_setMultiplier_reindexesDebt() public {
        vm.prank(borrower);
        market.borrow(borrower, 200e18);

        market.setMarketMultiplier(2e27);
        assertApproxEqAbs(market.totalDebt(), 400e18, 1e12);
    }

    function test_borrow_zero_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(IBaseMarket.InvalidPrincipal.selector);
        market.borrow(borrower, 0);
    }

    function test_repay_zero_reverts() public {
        vm.prank(borrower);
        market.borrow(borrower, 100e18);
        vm.prank(borrower);
        vm.expectRevert(IBaseMarket.InvalidAmount.selector);
        market.repay(0);
    }

    function test_liquidate_amountCappedToMax() public {
        vm.prank(borrower);
        market.borrow(borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);

        uint256 max = market.maxLiquidatable();
        assertGt(max, 0);

        _mintStable(defaultLiquidator, max);

        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(borrower, type(uint256).max);
        assertLe(repaid, max);
        assertGt(repaid, 0);
    }
}
