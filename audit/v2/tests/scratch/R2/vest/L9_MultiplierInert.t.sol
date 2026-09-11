// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// R2 port of D1_MultiplierInert (L-9): the market multiplier scales the cumulative liquidity
/// INDEX, and a floating market's accrual is a ratio of two index readings, so it cancels.
contract L9_MultiplierInert is CapDeployer {
    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
    }

    function _twoMarkets(uint256 multB) internal returns (uint256 liqA, uint256 liqB) {
        MarketBundle memory a = _createReadyMarket("A");
        MarketBundle memory b = _createReadyMarket("B");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        _fundTranche(b.tranche0Addr, makeAddr("ub"), 10_000e18);
        a.market.setUnderwriterRate(0);
        b.market.setUnderwriterRate(0);
        b.market.setMarketMultiplier(multB);
        assertEq(irm.marketMultiplier(a.marketAddr), 1e27);
        assertEq(irm.marketMultiplier(b.marketAddr), multB);

        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 365 days);
        (liqA,) = a.market.premium();
        (liqB,) = b.market.premium();
    }

    function test_L9_floatingMultiplierChangesNothing() public {
        (uint256 liqA, uint256 liqB) = _twoMarkets(2e27);
        emit log_named_uint("liquidity rate (ray/yr)     ", irm.liquidityRate());
        emit log_named_uint("premium at multiplier 1x    ", liqA);
        emit log_named_uint("premium at multiplier 2x    ", liqB);
        emit log_named_uint("difference (wei)            ", liqB > liqA ? liqB - liqA : liqA - liqB);
        assertGt(liqB, liqA * 15 / 10, "2x multiplier must charge materially more liquidity premium");
    }

    /// Fuzz: for ANY admissible multiplier the floating premium is identical to the wei.
    function testFuzz_L9_floatingMultiplierInertToTheWei(uint256 mult) public {
        mult = bound(mult, irm.minimumMarketMultiplier(), irm.maximumMarketMultiplier());
        (uint256 liqA, uint256 liqB) = _twoMarkets(mult);
        assertApproxEqAbs(
            liqB, liqA, 1, "multiplier is inert on floating: premium identical to within 1 wei of index rounding"
        );
    }

    function test_L9_floatingMultiplierSetMidwayAlsoChangesNothing() public {
        MarketBundle memory a = _createReadyMarket("A");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        a.market.setUnderwriterRate(0);
        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        uint256 d0 = a.market.totalDebt();
        a.market.setMarketMultiplier(2e27);
        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        uint256 d1 = a.market.totalDebt();
        emit log_named_uint("growth first 100d (1x) ", d0 - 1_000e18);
        emit log_named_uint("growth next 100d  (2x) ", d1 - d0);
        assertGt(d1 - d0, (d0 - 1_000e18) * 15 / 10, "2x multiplier must accrue materially faster");
    }

    function test_L9_fixedMultiplierWorks_forContrast() public {
        (address ma,) = _createFixedMarket("FA", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        (address mb,) = _createFixedMarket("FB", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        FixedMarket(ma).setUnderwriterRate(0);
        FixedMarket(mb).setUnderwriterRate(0);
        FixedMarket(mb).setMarketMultiplier(2e27);
        (uint256 la,) = FixedMarket(ma).premiumForBorrow(1_000e18, 30 days);
        (uint256 lb,) = FixedMarket(mb).premiumForBorrow(1_000e18, 30 days);
        emit log_named_uint("fixed premium 1x", la);
        emit log_named_uint("fixed premium 2x", lb);
        assertApproxEqAbs(lb, la * 2, 2, "fixed market multiplier doubles the liquidity premium");
    }
}
