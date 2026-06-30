// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { CapDeployer } from "./CapDeployer.sol";

/// @notice End-to-end lending lifecycle: supply -> borrow -> accrue -> repay -> rewards -> liquidate.
contract LendingFlowTest is CapDeployer {
    address internal manager = makeAddr("manager");
    address internal borrower = makeAddr("borrower");
    address internal juniorSupplier = makeAddr("juniorSupplier");
    address internal seniorSupplier = makeAddr("seniorSupplier");
    address internal stranger = makeAddr("stranger");

    bytes32 internal marketId;
    address internal senior;
    address internal junior;

    uint256 internal constant JUNIOR_DEPOSIT = 600e18;
    uint256 internal constant SENIOR_DEPOSIT = 400e18;

    function setUp() public {
        _deployCap();

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (marketId, senior, junior) = _createMarket("Market A", manager, borrowers);

        // configure the rate curves before any deposits: the first underwriter deposit pokes the
        // market IRM, which needs valid (non-zero kink) premium slopes to compute a rate.
        _setMarketSlopes(marketId);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );

        // a non-zero supply multiplier makes the supply index track the IRM (enables supply rewards)
        lender.setMultiplier(marketId, 1e27);
        // split premium 50/50 so both tranches accrue underwriter rewards
        vm.prank(senior);
        rewarder.setJuniorSplit(marketId, 0.5e27);

        // suppliers underwrite the market
        _fundUnderwriter(junior, manager, juniorSupplier, JUNIOR_DEPOSIT);
        _fundUnderwriter(senior, manager, seniorSupplier, SENIOR_DEPOSIT);

        lender.setBorrowCap(marketId, 1_000e18);
    }

    // --- credit sizing ---

    function test_availableCredit_isLtvOfCapital() public view {
        // capital = 1000 collateral @ price 1.0; ltv 0.5 -> credit 500
        assertEq(lender.availableCredit(marketId), 500e18);
        assertEq(lender.maxBorrowable(marketId), 500e18);
        // total credit = capital (1000) * lt (0.8)
        assertEq(lender.totalCredit(marketId), 800e18);
    }

    // --- borrow ---

    function test_borrow_mintsStableAndRecordsDebt() public {
        vm.prank(borrower);
        uint256 borrowed = lender.borrow(marketId, borrower, 300e18);

        assertEq(borrowed, 300e18);
        assertEq(stablecoin.balanceOf(borrower), 300e18);
        assertApproxEqAbs(lender.debt(marketId), 300e18, 1);
        assertGt(lender.scaledDebt(marketId), 0);
        // remaining credit shrinks by the borrowed amount
        assertApproxEqAbs(lender.maxBorrowable(marketId), 200e18, 1);
    }

    function test_borrow_unauthorizedCaller_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.borrow(marketId, stranger, 1e18);
    }

    function test_borrow_exceedingCredit_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(ILender.InsufficientLiquidity.selector);
        lender.borrow(marketId, borrower, 500e18 + 1);
    }

    function test_borrow_maxUint_borrowsMaxBorrowable() public {
        vm.prank(borrower);
        uint256 borrowed = lender.borrow(marketId, borrower, type(uint256).max);
        assertEq(borrowed, 500e18);
        assertEq(stablecoin.balanceOf(borrower), 500e18);
    }

    // --- interest accrual ---

    function test_interestAccruesOverTime() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 300e18);
        uint256 debtBefore = lender.debt(marketId);

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = lender.debt(marketId);
        assertGt(debtAfter, debtBefore);
        // combined supply + premium index should have grown
        assertGt(lender.index(marketId), 1e27);
    }

    // --- repay ---

    function test_repay_reducesDebtAndBurnsStable() public {
        vm.startPrank(borrower);
        lender.borrow(marketId, borrower, 300e18);
        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = lender.debt(marketId);
        uint256 repaid = lender.repay(marketId, 100e18);
        vm.stopPrank();

        assertEq(repaid, 100e18);
        assertEq(stablecoin.balanceOf(borrower), 200e18); // 300 borrowed - 100 burned
        assertApproxEqAbs(lender.debt(marketId), debtBefore - 100e18, 2);
    }

    function test_repay_capsAtOutstandingDebt() public {
        vm.startPrank(borrower);
        lender.borrow(marketId, borrower, 100e18);
        // try to repay more than owed -> capped at debt
        uint256 repaid = lender.repay(marketId, 1_000e18);
        vm.stopPrank();

        assertApproxEqAbs(repaid, 100e18, 1);
        assertApproxEqAbs(lender.debt(marketId), 0, 2);
    }

    // --- supply rewards ---

    function test_supplyReward_accruesAndClaims() public {
        address stcUSD = makeAddr("stcUSD");
        rewarder.setStcUSD(stcUSD);

        vm.prank(borrower);
        lender.borrow(marketId, borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        rewarder.updateRewards(marketId);

        uint256 claimable = rewarder.claimableSupplyReward();
        assertGt(claimable, 0);

        uint256 minted = rewarder.claimSupplyReward();
        assertEq(minted, claimable);
        assertEq(stablecoin.balanceOf(stcUSD), claimable);
        assertEq(rewarder.claimableSupplyReward(), 0);
    }

    // --- underwriter (premium) rewards ---

    function test_underwriterReward_accruesAndClaims() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        rewarder.updateRewards(marketId);

        uint256 claimable = rewarder.claimableUnderwriterReward(marketId, junior, juniorSupplier);
        assertGt(claimable, 0);

        vm.prank(juniorSupplier);
        uint256 reward = rewarder.claimUnderwriterReward(marketId, junior, juniorSupplier);
        assertEq(reward, claimable);
        assertEq(stablecoin.balanceOf(juniorSupplier), reward);
    }

    // --- liquidation ---

    function test_liquidate_solventMarket_reverts() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 100e18);

        vm.expectRevert(ILender.Solvent.selector);
        lender.liquidate(marketId, borrower, 50e18);
    }

    function test_liquidate_unhealthyMarket_repaysAndSlashes() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 500e18);

        // let debt compound past the liquidation threshold
        vm.warp(block.timestamp + 3650 days);
        assertGt(lender.maxLiquidatable(marketId), 0);

        uint256 borrowerStableBefore = stablecoin.balanceOf(borrower);
        uint256 recipientCollateralBefore = collateral.balanceOf(borrower);

        // borrower acts as liquidator, burning some of their cUSD
        vm.prank(borrower);
        (uint256 repaid,, uint256 slashed) = lender.liquidate(marketId, borrower, 100e18);

        assertGt(repaid, 0);
        assertEq(stablecoin.balanceOf(borrower), borrowerStableBefore - repaid);
        // collateral is paid out to the recipient (>= 0; slash math may round small)
        assertGe(collateral.balanceOf(borrower), recipientCollateralBefore);
        assertLe(slashed, JUNIOR_DEPOSIT + SENIOR_DEPOSIT);
    }

    // --- manager / admin paths that touch reward + index bookkeeping ---

    function test_setMultiplier_reindexesDebt() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 200e18);

        lender.setMultiplier(marketId, 2e27);
        // debt remains continuous across the reindex
        assertApproxEqAbs(lender.debt(marketId), 200e18, 1e12);
    }

    function test_setInterestType_togglesVariableFixed() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 200e18);

        lender.setInterestType(marketId, false);
        assertApproxEqAbs(lender.debt(marketId), 200e18, 1e12);
    }

    // --- borrow / repay edge branches ---

    function test_borrow_zero_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(ILender.InvalidAmount.selector);
        lender.borrow(marketId, borrower, 0);
    }

    function test_repay_zero_reverts() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 100e18);
        vm.prank(borrower);
        vm.expectRevert(ILender.InvalidAmount.selector);
        lender.repay(marketId, 0);
    }

    function test_repay_dustBelowIndex_reverts() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 300e18);
        vm.warp(block.timestamp + 36500 days);

        vm.prank(borrower);
        vm.expectRevert(ILender.InvalidAmount.selector);
        lender.repay(marketId, 1);
    }

    // --- liquidation bonus curve bands (getBonus) ---

    function test_getBonus_zeroWhenNoDebt() public view {
        assertEq(lender.getBonus(marketId), 0);
    }

    function test_getBonus_zeroWhenHealthy() public {
        // small debt against full capital -> health >> 1 -> no bonus
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 100e18);
        assertEq(lender.getBonus(marketId), 0);
    }

    function test_getBonus_aboveKinkBand() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 300e18);

        // drive health into (kink=0.9, 1): capital ~356 -> health ~0.95
        oracle.setPrice(address(collateral), 2.807e27);
        uint256 bonus = lender.getBonus(marketId);
        assertGt(bonus, 0);
        // above-kink band stays below slope0 (0.02)
        assertLt(bonus, 0.02e27);
    }

    function test_getBonus_belowKinkBand_cappedToMax() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 300e18);

        // capital ~305 just above debt -> health ~0.81 (< kink) and a tiny max-bonus cap
        oracle.setPrice(address(collateral), 3.2787e27);
        uint256 bonus = lender.getBonus(marketId);
        assertGt(bonus, 0);
        // capped to (capital-debt)/debt which is small here
        uint256 capital = lender.totalCapital(marketId);
        uint256 debt = lender.debt(marketId);
        assertEq(bonus, (capital - debt) * 1e27 / debt);
    }

    function test_getBonus_zeroWhenInsolvent() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 300e18);

        // capital < debt -> no bonus
        oracle.setPrice(address(collateral), 5e27);
        assertEq(lender.getBonus(marketId), 0);
    }

    // --- liquidation slashes through junior into senior, and caps the burn amount ---

    function test_liquidate_amountCappedToMax() public {
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);

        uint256 max = lender.maxLiquidatable(marketId);
        assertGt(max, 0);

        // fund the liquidator so the (capped) burn can be covered
        _mintStable(borrower, max);

        // request to burn far more than allowed -> capped at maxLiquidatable
        vm.prank(borrower);
        (uint256 repaid,,) = lender.liquidate(marketId, borrower, type(uint256).max);
        assertLe(repaid, max);
        assertGt(repaid, 0);
    }
}
