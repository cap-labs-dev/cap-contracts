// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IMarket } from "../../contracts/interfaces/IMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice End-to-end lending lifecycle: supply -> borrow -> accrue -> repay -> rewards -> liquidate.
contract LendingFlowTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal juniorSupplier = makeAddr("juniorSupplier");
    address internal seniorSupplier = makeAddr("seniorSupplier");
    address internal stranger = makeAddr("stranger");
    uint64 internal managerId = MANAGER_ROLE;
    uint64 internal borrowerId = BORROWER_ROLE;
    Market internal market;
    address internal senior;
    address internal junior;

    uint256 internal constant JUNIOR_DEPOSIT = 600e18;
    uint256 internal constant SENIOR_DEPOSIT = 400e18;

    function setUp() public {
        _deployCap();

        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("Market A", managerId, borrowerId);
        market = Market(marketAddr);
        accessManager.grantRole(BORROWER_ROLE, borrower, 0);

        _setMarketSlopes(marketAddr);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );

        market.setMultiplier(1e27);
        market.setJuniorSplit(0.5e27);

        _fundTranche(junior, juniorSupplier, JUNIOR_DEPOSIT);
        _fundTranche(senior, seniorSupplier, SENIOR_DEPOSIT);

        market.setBorrowCap(1_000e18);
    }

    function test_availableCredit_isLtvOfCapital() public view {
        assertEq(market.availableCredit(), 500e18);
        assertEq(market.maxBorrowable(), 500e18);
        assertEq(market.totalCredit(), 800e18);
    }

    function test_borrow_mintsStableAndRecordsDebt() public {
        vm.prank(borrower);
        uint256 borrowed = market.borrow(borrower, 300e18);

        assertEq(borrowed, 300e18);
        assertEq(stablecoin.balanceOf(borrower), 300e18);
        assertApproxEqAbs(market.debt(), 300e18, 1);
        assertApproxEqAbs(market.maxBorrowable(), 200e18, 1);
    }

    function test_borrow_unauthorizedCaller_reverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.borrow(stranger, 1e18);
    }

    function test_borrow_exceedingCredit_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(IMarket.InsufficientLiquidity.selector);
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
        uint256 debtBefore = market.debt();

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = market.debt();
        assertGt(debtAfter, debtBefore);
    }

    function test_repay_reducesDebtAndBurnsStable() public {
        vm.startPrank(borrower);
        market.borrow(borrower, 300e18);
        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = market.debt();
        uint256 repaid = market.repay(100e18);
        vm.stopPrank();

        assertEq(repaid, 100e18);
        assertEq(stablecoin.balanceOf(borrower), 200e18);
        assertApproxEqAbs(market.debt(), debtBefore - 100e18, 2);
    }

    function test_repay_capsAtOutstandingDebt() public {
        vm.startPrank(borrower);
        market.borrow(borrower, 100e18);
        uint256 repaid = market.repay(1_000e18);
        vm.stopPrank();

        assertApproxEqAbs(repaid, 100e18, 1);
        assertApproxEqAbs(market.debt(), 0, 2);
    }

    function test_supplyReward_accruesToYieldRecipient() public {
        address stcUSD = makeAddr("stcUSD");
        market.setStakedStablecoin(stcUSD);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        market.repay(1);

        assertGt(stablecoin.balanceOf(stcUSD), 0);
    }

    function test_underwriterReward_accruesAndClaims() public {
        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        market.repay(1);

        vm.prank(juniorSupplier);
        uint256 reward = Tranche(junior).claim(juniorSupplier);
        assertGt(reward, 0);
        assertEq(stablecoin.balanceOf(juniorSupplier), reward);
    }

    function test_liquidate_solventMarket_reverts() public {
        vm.prank(borrower);
        market.borrow(borrower, 100e18);

        vm.expectRevert(IMarket.Solvent.selector);
        market.liquidate(borrower, 50e18);
    }

    function test_liquidate_unhealthyMarket_repaysAndSlashes() public {
        vm.prank(borrower);
        market.borrow(borrower, 500e18);

        vm.warp(block.timestamp + 3650 days);
        assertGt(market.maxLiquidatable(), 0);

        uint256 borrowerStableBefore = stablecoin.balanceOf(borrower);
        uint256 recipientCollateralBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        (uint256 repaid, uint256 slashed) = market.liquidate(borrower, 100e18);

        assertGt(repaid, 0);
        assertEq(stablecoin.balanceOf(borrower), borrowerStableBefore - repaid);
        assertGe(collateral.balanceOf(borrower), recipientCollateralBefore);
        assertLe(slashed, JUNIOR_DEPOSIT + SENIOR_DEPOSIT);
    }

    function test_setMultiplier_reindexesDebt() public {
        vm.prank(borrower);
        market.borrow(borrower, 200e18);

        market.setMultiplier(2e27);
        assertApproxEqAbs(market.debt(), 200e18, 1e12);
    }

    function test_setInterestType_togglesVariableFixed() public {
        vm.prank(borrower);
        market.borrow(borrower, 200e18);

        market.setInterestType(false);
        assertApproxEqAbs(market.debt(), 200e18, 1e12);
    }

    function test_borrow_zero_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(IMarket.InvalidAmount.selector);
        market.borrow(borrower, 0);
    }

    function test_repay_zero_reverts() public {
        vm.prank(borrower);
        market.borrow(borrower, 100e18);
        vm.prank(borrower);
        vm.expectRevert(IMarket.InvalidAmount.selector);
        market.repay(0);
    }

    function test_getBonus_zeroWhenNoDebt() public view {
        assertEq(market.bonus(), 0);
    }

    function test_getBonus_zeroWhenHealthy() public {
        vm.prank(borrower);
        market.borrow(borrower, 100e18);
        assertEq(market.bonus(), 0);
    }

    function test_getBonus_aboveKinkBand() public {
        vm.prank(borrower);
        market.borrow(borrower, 300e18);

        oracle.setPrice(address(collateral), 2.807e27);
        uint256 bonus = market.bonus();
        assertGt(bonus, 0);
        assertLt(bonus, 0.02e27);
    }

    function test_getBonus_belowKinkBand_cappedToMax() public {
        vm.prank(borrower);
        market.borrow(borrower, 300e18);

        oracle.setPrice(address(collateral), 3.2787e27);
        uint256 bonus = market.bonus();
        assertGt(bonus, 0);
        uint256 capital = market.totalCapital();
        uint256 debt = market.debt();
        assertEq(bonus, (capital - debt) * 1e27 / debt);
    }

    function test_getBonus_zeroWhenInsolvent() public {
        vm.prank(borrower);
        market.borrow(borrower, 300e18);

        oracle.setPrice(address(collateral), 5e27);
        assertEq(market.bonus(), 0);
    }

    function test_liquidate_amountCappedToMax() public {
        vm.prank(borrower);
        market.borrow(borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);

        uint256 max = market.maxLiquidatable();
        assertGt(max, 0);

        _mintStable(borrower, max);

        vm.prank(borrower);
        (uint256 repaid,) = market.liquidate(borrower, type(uint256).max);
        assertLe(repaid, max);
        assertGt(repaid, 0);
    }
}
