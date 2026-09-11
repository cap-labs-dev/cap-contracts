// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { WadRayMath } from "../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D. Does liquidating exactly maxLiquidatable land health on targetHealth, and what does
/// a liquidation do in the regime where debt already exceeds recoverableDebt?
contract D6_MaxLiquidatable is CapDeployer {
    using WadRayMath for uint256;

    function setUp() public {
        _deployCap();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_maxLiquidatableLandsOnTarget(uint256 rawPrice, uint256 rawTarget, uint256 rawBonus) public {
        uint256 bonus = bound(rawBonus, 0, 0.1e27);
        uint256 target = bound(rawTarget, 1.25e27, 3e27);
        irm.setLiquidationBonus(bonus);
        MarketBundle memory b = _createReadyMarket("F");
        b.market.setTargetHealth(target);
        _fundTranche(b.tranche0Addr, makeAddr("a"), 6_000e18);
        _fundTranche(b.tranche1Addr, makeAddr("b"), 4_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max); // 5_000 at ltv 0.5

        // price falls enough to be unhealthy (debt > 0.8*C -> C < 6250 -> price < 0.625)
        uint256 price = bound(rawPrice, 0.3e18, 0.624e18);
        oracle.setPrice(address(collateral), price);
        vm.assume(b.market.healthiness() < 1e27);
        // exclude the degenerate boundary debt == recoverableDebt, where liquidating everything is the
        // answer and health reads 1 ray by the debt == 0 convention
        bool recoverable = b.market.totalDebt() * 1000 < b.market.recoverableDebt() * 999;

        uint256 debtBefore = b.market.totalDebt();
        uint256 recoverableBefore = b.market.recoverableDebt();
        uint256 maxLiq = b.market.maxLiquidatable();
        _depositStable(defaultLiquidator, maxLiq + 1e18);
        uint256 healthBefore = b.market.healthiness();
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = b.market.liquidate(defaultLiquidator, type(uint256).max);
        assertApproxEqAbs(repaid, maxLiq, 2, "took the max");
        uint256 healthAfter = b.market.healthiness();

        if (recoverable) {
            assertApproxEqRel(healthAfter, target, 1e12, "lands on target health");
        } else if (debtBefore * 999 > recoverableBefore * 1000) {
            // beyond the recoverable point liquidation drains the collateral and health only falls
            assertLe(healthAfter, healthBefore, "health falls");
            assertEq(b.market.totalCapital() / 1e6, 0, "collateral exhausted");
        }
    }

    /// @dev Repeated small liquidations vs one big one: partials stop at health >= 1, so they
    /// extract strictly less than one call sized at maxLiquidatable.
    function test_partialsExtractLessThanOneBig() public {
        MarketBundle memory b = _createReadyMarket("F");
        _fundTranche(b.tranche0Addr, makeAddr("a"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        oracle.setPrice(address(collateral), 0.55e18);
        uint256 snap = vm.snapshotState();

        _depositStable(defaultLiquidator, 10_000e18);
        vm.prank(defaultLiquidator);
        (uint256 big,) = b.market.liquidate(defaultLiquidator, type(uint256).max);
        emit log_named_uint("one big liquidation repaid", big);
        emit log_named_uint("health after big          ", b.market.healthiness());

        vm.revertToState(snap);
        _depositStable(defaultLiquidator, 10_000e18);
        uint256 total;
        for (uint256 i; i < 200; ++i) {
            if (b.market.healthiness() >= 1e27) break;
            vm.prank(defaultLiquidator);
            (uint256 r,) = b.market.liquidate(defaultLiquidator, 10e18);
            total += r;
        }
        emit log_named_uint("200 x 10e18 partials repaid", total);
        emit log_named_uint("health after partials      ", b.market.healthiness());
        assertLt(total, big, "partials extract less");
    }
}
