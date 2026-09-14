// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice Killing tests for the fixed market's partial-amount paths.
///
/// Gambit `FixedMarket#129` turns `debt[id] = loanDebt - amount` into `loanDebt % amount` in
/// {writeOff}; it survives because the only capped write-off test has a shortfall above half the
/// loan, and `a % b == a - b` whenever `b > a / 2`. `FixedMarket#161` turns `rate - low` into
/// `rate % low` in the same-window catch-up of {availableCredit}; it and hand mutant H25 (catch-up
/// deleted) survive because no test draws twice in one averaging window against a binding limit.
/// H19 drops the post-extension health check. (H20, the post-borrow check, is unreachable by construction:
/// `availableCredit(term)` already sizes principal plus worst-case premium inside the limit.)
contract FixedPartialKillTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1_000e18;

    function setUp() public {
        _deployCap();
    }

    function _readyFixed(uint256 capital) internal returns (FixedMarket market, address t0) {
        address marketAddr;
        (marketAddr, t0,) = _createFixedMarket("Fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t0, makeAddr("senior"), capital);
    }

    /// Kills FixedMarket#129: a small partial liquidation must clear exactly what it repaid.
    function test_smallPartialLiquidationClearsExactlyWhatItRepaid() public {
        (FixedMarket market,) = _readyFixed(10_000e18);

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days);

        _setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27, "unhealthy");
        assertGt(market.maxLiquidatable(), 10e18, "room for a small repayment");

        uint256 loanBefore = market.debt(id);
        uint256 totalBefore = market.totalDebt();
        _depositStable(defaultLiquidator, 10e18); // real reserve, so credit-backed supply is untouched

        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(id, defaultLiquidator, 10e18);

        assertEq(repaid, 10e18, "the small request is honoured in full");
        assertEq(market.debt(id), loanBefore - 10e18, "the loan drops by exactly the repayment");
        assertEq(market.totalDebt(), totalBefore - 10e18, "and so does the market");
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "credit-backed supply tracks it");
    }

    /// Kills FixedMarket#161: a shortfall smaller than half the market's debt must come off the
    /// aggregate exactly. Two loans of 2000 against 10 000 of capital, collateral falls to $0.30.
    function test_smallWriteOffComesOffTheAggregateExactly() public {
        (FixedMarket market,) = _readyFixed(10_000e18);

        vm.startPrank(defaultBorrower);
        (uint256 a,) = market.borrow(defaultBorrower, 2_000e18, 30 days);
        (uint256 b,) = market.borrow(defaultBorrower, 2_000e18, 30 days);
        vm.stopPrank();

        // $3500 of capital against ~$4100 of debt: recoverable ~3431, shortfall ~670, under half of loan a
        _setPrice(address(collateral), 0.35e18);
        uint256 shortfall = market.unrecoverableDebt();
        uint256 totalBefore = market.totalDebt();
        uint256 loanBefore = market.debt(a);
        assertGt(shortfall, 0, "the market is short");
        assertLt(shortfall, loanBefore / 2, "by less than half the loan it lands on");

        uint256 written = market.writeOff(a);

        assertEq(written, shortfall, "the whole shortfall lands on loan a");
        assertEq(market.debt(a), loanBefore - shortfall, "the loan falls by exactly the write-off");
        assertEq(market.totalDebt(), totalBefore - shortfall, "the aggregate falls by exactly the write-off");
        assertEq(market.debt(a) + market.debt(b), market.totalDebt(), "and the loans still sum to it");
        assertEq(market.unrecoverableDebt(), 0, "nothing is left unrecoverable");
    }

    /// Kills FixedMarket#161 and H25: a second draw in the same averaging window must still land
    /// inside the credit limit once the catch-up premium on the first draw is charged at the
    /// higher rate. The curve is steep past the kink so the second draw's rate is well over twice
    /// the first's, which is where `rate % low` and `rate - low` part company.
    function test_twoSameWindowDrawsStayInsideTheCreditLimit() public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.01e27, slope0: 0.01e27, slope1: 3e27, kink: 0.3e27 })
        );
        (FixedMarket market,) = _readyFixed(1_000e18);
        market.setLtv(capConfig.defaultLt - capConfig.defaultBuffer); // limit 700 against an 800 threshold
        _depositStable(makeAddr("saver"), 1_000e18);
        vm.warp(block.timestamp + 20 * irm.averagingPeriod()); // let the reserve settle into the average

        uint256 limit = market.creditLimit();
        assertEq(limit, 700e18);

        vm.startPrank(defaultBorrower);
        market.borrow(defaultBorrower, 300e18, 30 days);
        uint256 low = irm.liquidityRate();
        uint256 room = market.availableCredit(30 days);
        assertGt(room, 0, "there is room for a second draw");
        market.borrow(defaultBorrower, type(uint256).max, 30 days);
        vm.stopPrank();

        assertGt(irm.liquidityRate(), 2 * low, "the second draw crossed the kink");
        assertLe(market.totalDebt(), limit, "principal plus both premiums fit inside the limit");
        assertGe(market.healthiness(), 1e27);
    }

    /// Kills H19: an extension whose premium carries the debt over the liquidation threshold must
    /// revert Unhealthy rather than leave a liquidatable market behind.
    function test_extensionThatBreachesTheThresholdIsRefused() public {
        (FixedMarket market,) = _readyFixed(1_000e18);
        market.setLtv(capConfig.defaultLt - capConfig.defaultBuffer); // 0.7, so a max draw sits near the threshold
        market.setUnderwriterRate(1e27); // 100 % a year makes the extension premium material

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, 1 days);
        assertGe(market.healthiness(), 1e27, "healthy after the draw");

        // collateral slips until the 29-day extension premium is what tips it over
        _setPrice(address(collateral), 0.88e18);
        assertGe(market.healthiness(), 1e27, "still healthy before extending");
        uint256 debtBefore = market.debt(id);
        (uint256 liq, uint256 uw) = market.premiumForExtension(debtBefore, 29 days);
        assertGt(debtBefore + liq + uw, market.debtLiquidationThreshold(), "the extension would breach the threshold");

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.Unhealthy.selector);
        market.extend(id, 29 days);

        assertEq(market.debt(id), debtBefore, "nothing was charged");
    }
}
