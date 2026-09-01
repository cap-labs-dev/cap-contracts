// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title RateConventionTest
/// @notice Both market types read the same rates from the interest rate model, so both must
/// interpret them as annualized ray values. {MathUtils} divides by a year internally; the fixed
/// market prorates its term against a year to match.
contract RateConventionTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1_000e18;
    uint256 internal constant RATE_20PCT_PER_YEAR = 0.2e27;

    function setUp() public {
        _deployCap();
    }

    function test_floatingMarket_accruesAnnualRateOverOneYear() public {
        (address marketAddr, address t0,) = _createMarket("Floating");
        FloatingMarket market = FloatingMarket(marketAddr);
        market.setUnderwriterRate(RATE_20PCT_PER_YEAR);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);

        vm.warp(block.timestamp + 365 days);

        // continuously compounded 20% => e^0.2 - 1 ~= 22.14%
        assertApproxEqRel(market.totalDebt(), 1_221.4e18, 0.01e18, "floating annual accrual");
    }

    function test_fixedMarket_proratesAnnualRateOverTerm() public {
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        FixedMarket market = FixedMarket(marketAddr);
        market.setUnderwriterRate(RATE_20PCT_PER_YEAR);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 30 days);

        // 20% per year prorated over 30 days = 1.6438%
        uint256 expectedPremium = PRINCIPAL * 20 * 30 days / (100 * 365 days);
        assertApproxEqRel(market.debt(id) - PRINCIPAL, expectedPremium, 0.001e18, "fixed term premium");
    }

    /// Over a short window the two markets should charge almost the same amount for the same rate,
    /// since compounding has barely diverged from simple interest yet.
    function test_bothMarkets_agreeOverTheSameWindow() public {
        (address floatingAddr, address ft0,) = _createMarket("Floating");
        FloatingMarket floating = FloatingMarket(floatingAddr);
        floating.setUnderwriterRate(RATE_20PCT_PER_YEAR);
        floating.setFixedCreditLimit(10_000e18);
        _fundTranche(ft0, makeAddr("floatingSenior"), 10_000e18);

        (address fixedAddr, address xt0,) = _createFixedMarket("Fixed");
        FixedMarket fixedMarket = FixedMarket(fixedAddr);
        fixedMarket.setUnderwriterRate(RATE_20PCT_PER_YEAR);
        fixedMarket.setFixedCreditLimit(10_000e18);
        _fundTranche(xt0, makeAddr("fixedSenior"), 10_000e18);

        vm.prank(defaultBorrower);
        floating.borrow(defaultBorrower, PRINCIPAL);
        vm.prank(defaultBorrower);
        (uint256 id,) = fixedMarket.borrow(defaultBorrower, PRINCIPAL, 30 days);

        uint256 fixedCost = fixedMarket.debt(id) - PRINCIPAL;

        vm.warp(block.timestamp + 30 days);
        uint256 floatingCost = floating.totalDebt() - PRINCIPAL;

        assertApproxEqRel(floatingCost, fixedCost, 0.01e18, "markets disagree on the same rate");
    }

    /// A non-zero liquidity rate must be usable by a fixed market, not blow up its credit.
    function test_fixedMarket_withLiquiditySlopes() public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        irm.setTermMultiplierSlopes(IInterestRateModel.Slopes({ base: 0, slope0: 1e27, slope1: 0, kink: 0.8e27 }));

        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        FixedMarket market = FixedMarket(marketAddr);
        market.setUnderwriterRate(RATE_20PCT_PER_YEAR);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);

        // nothing is borrowed yet, so utilization is zero and the liquidity rate is just base
        assertEq(irm.liquidityRate(), 0.05e27, "liquidity rate at zero utilization");

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 30 days);

        // the borrow mints credit-backed cUSD, and since no real deposits exist utilization jumps
        // above the kink, taking the liquidity rate to base + slope0 + slope1 = 20% per year
        assertEq(irm.liquidityRate(), 0.2e27, "liquidity rate at full utilization");

        // the premium is charged after the mint, so it uses 20% liquidity + 20% underwriter = 40%
        // per year, prorated over 30 days ~= 3.288%
        uint256 expectedPremium = PRINCIPAL * 40 * 30 days / (100 * 365 days);
        assertApproxEqRel(market.debt(id) - PRINCIPAL, expectedPremium, 0.01e18, "combined term premium");
    }
}
