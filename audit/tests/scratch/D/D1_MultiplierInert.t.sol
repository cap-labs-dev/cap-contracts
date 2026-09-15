// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D: the per-market liquidity multiplier multiplies the cumulative liquidity INDEX
/// (IRM.liquidityIndex = _index(liquidityData).rayMul(multiplier)). A floating market's accrual is
/// the RATIO of two index readings, and a constant factor cancels out of a ratio. So the multiplier
/// has no effect at all on a floating market's premium. The fixed market multiplies the RATE and
/// works. Expected: 2x multiplier => ~2x liquidity premium.
contract D1_MultiplierInert is CapDeployer {
    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
    }

    function test_floatingMultiplierChangesNothing() public {
        // two identical floating markets, one at 1x and one at 2x
        MarketBundle memory a = _createReadyMarket("A");
        MarketBundle memory b = _createReadyMarket("B");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        _fundTranche(b.tranche0Addr, makeAddr("ub"), 10_000e18);
        a.market.setUnderwriterRate(0);
        b.market.setUnderwriterRate(0);
        b.market.setMarketMultiplier(2e27);
        assertEq(irm.marketMultiplier(a.marketAddr), 1e27);
        assertEq(irm.marketMultiplier(b.marketAddr), 2e27);

        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 365 days);
        (uint256 liqA,) = a.market.premium();
        (uint256 liqB,) = b.market.premium();
        emit log_named_uint("liquidity rate (ray/yr)     ", irm.liquidityRate());
        emit log_named_uint("premium at multiplier 1x    ", liqA);
        emit log_named_uint("premium at multiplier 2x    ", liqB);

        // a 2x multiplier should charge (about) twice the liquidity premium
        assertGt(liqB, liqA * 15 / 10, "2x multiplier must charge materially more liquidity premium");
    }

    function test_floatingMultiplierSetMidwayAlsoChangesNothing() public {
        MarketBundle memory a = _createReadyMarket("A");
        _fundTranche(a.tranche0Addr, makeAddr("ua"), 10_000e18);
        a.market.setUnderwriterRate(0);
        vm.prank(defaultBorrower);
        a.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        uint256 d0 = a.market.totalDebt();
        // raise to 2x now; the next 100 days should accrue faster than the last 100
        a.market.setMarketMultiplier(2e27);
        vm.warp(block.timestamp + 100 days);
        a.market.chargePremium();
        uint256 d1 = a.market.totalDebt();
        emit log_named_uint("growth first 100d (1x) ", d0 - 1_000e18);
        emit log_named_uint("growth next 100d  (2x) ", d1 - d0);
        assertGt(d1 - d0, (d0 - 1_000e18) * 15 / 10, "2x multiplier must accrue materially faster");
    }

    function test_fixedMultiplierWorks_forContrast() public {
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
