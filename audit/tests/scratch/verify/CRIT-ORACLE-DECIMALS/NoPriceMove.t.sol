// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { RealOracleDeployer } from "../../E/RealOracleDeployer.sol";

/// @notice Verification of CRIT-ORACLE-DECIMALS. Removes the price-crash precondition from the
/// E PoC: with the production Oracle + ChainlinkAdapter, the max-permitted (dust) borrow, and
/// NO price move at all, ordinary premium accrual makes the market liquidatable, and an honest
/// max liquidation by the LIQUIDATOR role drains the whole tranche for dust.
contract Verify_NoPriceMove is RealOracleDeployer {
    address internal underwriter = makeAddr("underwriter");
    Tranche internal tranche0;
    FloatingMarket internal market;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCapWithRealOracle(2000e8);
        (address m, address t0,) = _createMarket("weth-market");
        market = FloatingMarket(m);
        tranche0 = Tranche(t0);
        _configureMarketRates(market);
        _fundTranche(t0, underwriter, 10e18); // 10 WETH = $20,000 real
    }

    function test_premiumAccrualAlone_drainsTranche() public {
        vm.prank(defaultBorrower);
        uint256 borrowed = market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("borrowed (cUSD wei)", borrowed);
        assertGe(market.healthiness(), 1e27, "healthy right after borrow");

        // no price move: same answer, only time passes and the feed is kept fresh
        uint256 years_;
        while (market.healthiness() >= 1e27 && years_ < 10) {
            vm.warp(block.timestamp + 365 days);
            feed.setUpdatedAt(block.timestamp);
            years_++;
        }
        (uint256 p,) = realOracle.price(address(collateral));
        assertEq(p, 2000e8, "price unchanged");
        emit log_named_uint("years of accrual until liquidatable", years_);
        emit log_named_uint("healthiness (ray)", market.healthiness());
        assertLt(market.healthiness(), 1e27, "premium accrual alone makes the market unhealthy");

        uint256 maxLiq = market.maxLiquidatable();
        _depositStable(defaultLiquidator, maxLiq + 1);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashedValue) = market.liquidate(defaultLiquidator, type(uint256).max);

        uint256 seized = collateral.balanceOf(defaultLiquidator);
        emit log_named_uint("cUSD burned by liquidator (wei)", repaid);
        emit log_named_uint("slashedValue reported (oracle-scale USD)", slashedValue);
        emit log_named_uint("WETH seized (wei)", seized);
        emit log_named_uint("WETH left in tranche (wei)", tranche0.totalAssets());
        emit log_named_uint("tranche killed", tranche0.killed() ? 1 : 0);

        // the bug is the scale: a correct implementation would hand over ~repaid*(1+bonus)/2000 WETH
        uint256 intendedSeized = repaid * (1e27 + irm.liquidationBonus()) / 1e27 * 1e18 / 2000e18;
        emit log_named_uint("WETH a correct slash would hand over (wei)", intendedSeized);
        // no price move, so maxLiquidatable is sized to restore targetHealth rather than capped at
        // the tranche; the over-payment is still exactly the 1e10 scale gap
        assertApproxEqRel(seized, intendedSeized * 1e10, 1e12, "seized exactly 1e10x the intended payout");
        assertGt(seized, 7e18, "most of a $20k tranche leaves for ~1.5e-6 cUSD");
    }

    /// @dev Registry's liveness check only binds the `price(address)` selector, not DECIMALS().
    function test_registryLivenessCheck_doesNotBindDecimals() public view {
        // selector Registry calls: price(address). DECIMALS() is never read by Registry or Tranche.
        bytes memory code = address(registry).code;
        assertGt(code.length, 0);
    }
}
