// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Adversarial verification of MED-MULTIPLIER-INERT. Tries to find ANY multiplier in the
/// configured band, with a non-zero underwriter rate and multiple charge cadences, that changes a
/// floating borrower's liquidity premium. Also checks the mid-life re-index path bit-for-bit.
contract V_MultiplierInert is CapDeployer {
    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
    }

    /// fuzz the multiplier across the whole band and the charge cadence; premium must be within a
    /// handful of wei of the 1x market regardless
    function testFuzz_multiplierNeverMoves(uint256 m, uint8 charges) public {
        m = bound(m, irm.minimumMarketMultiplier(), irm.maximumMarketMultiplier());
        charges = uint8(bound(charges, 1, 12));
        MarketBundle memory a = _createReadyMarket("A");
        MarketBundle memory b = _createReadyMarket("B");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        _fundTranche(b.tranche0Addr, makeAddr("ub"), 10_000e18);
        a.market.setUnderwriterRate(0.1e27);
        b.market.setUnderwriterRate(0.1e27);
        b.market.setMarketMultiplier(m);

        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000e18);

        for (uint256 i; i < charges; i++) {
            vm.warp(block.timestamp + 365 days / charges);
            a.market.chargePremium();
            b.market.chargePremium();
        }
        uint256 da = a.market.totalDebt();
        uint256 db = b.market.totalDebt();
        emit log_named_uint("multiplier", m);
        emit log_named_uint("debt 1x  ", da);
        emit log_named_uint("debt m x ", db);
        assertApproxEqAbs(db, da, 1e6, "multiplier changed the accrual");
    }

    /// the re-index in setMarketMultiplier: growth over the next window is the same whether or
    /// not the multiplier was raised (compare against a control market that was not touched)
    function test_midLifeChangeMatchesControl() public {
        MarketBundle memory a = _createReadyMarket("A");
        MarketBundle memory c = _createReadyMarket("C");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        _fundTranche(c.tranche0Addr, makeAddr("uc"), 10_000e18);
        a.market.setUnderwriterRate(0.1e27);
        c.market.setUnderwriterRate(0.1e27);
        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);
        vm.prank(defaultBorrower);
        c.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        c.market.chargePremium();
        a.market.setMarketMultiplier(2e27);
        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        c.market.chargePremium();
        emit log_named_uint("debt raised to 2x mid-life", a.market.totalDebt());
        emit log_named_uint("debt control (1x)         ", c.market.totalDebt());
        assertApproxEqAbs(a.market.totalDebt(), c.market.totalDebt(), 1e6, "mid-life change moved accrual");
    }

    /// does anything ELSE in the floating market read the multiplier? healthiness, availableCredit,
    /// maxLiquidatable are all off totalDebt. Print them for a 1x and 2x market to be sure.
    function test_nothingElseReadsIt() public {
        MarketBundle memory a = _createReadyMarket("A");
        MarketBundle memory b = _createReadyMarket("B");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        _fundTranche(b.tranche0Addr, makeAddr("ub"), 10_000e18);
        b.market.setMarketMultiplier(2e27);
        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000e18);
        vm.warp(block.timestamp + 30 days);
        assertEq(a.market.healthiness(), b.market.healthiness(), "health");
        assertEq(a.market.availableCredit(), b.market.availableCredit(), "credit");
        assertApproxEqAbs(a.market.totalDebt(), b.market.totalDebt(), 10, "debt");
    }
}
