// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// WS-D item 1: derivation of maxLiquidatable / recoverableDebt / unrecoverableDebt and the
/// threshold at which the recoverableDebt cap binds. Deploy params: lt 0.8, buffer 0.1,
/// targetHealth 1.25, bonus 0.02.
contract D1_LiquidationMath is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    address senior;
    address junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("D1");
        market = FloatingMarket(m);
        senior = s;
        junior = j;
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, makeAddr("senior"), 500e18);
        _fundTranche(junior, makeAddr("junior"), 500e18);
    }

    /// Worked example: TC = $1000 at price 1, debt 500 (ltv 0.5). Price -> 0.55 gives TC = 550,
    /// health = 550*0.8/500 = 0.88 (in the partial band [0.816, 1)).
    /// maxLiquidatable = (1.25*500 - 550*0.8) / (1.25 - 1.02*0.8) = (625 - 440)/0.434 = 426.27
    /// recoverable = 550/1.02 = 539.2 > 426.27 so the formula is what binds; landing health = 1.25.
    function test_workedExample_partialBand() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.55e18);

        assertEq(market.totalCapital(), 550e18);
        assertEq(market.healthiness(), 0.88e27);
        uint256 expected = (uint256(625e18) - 440e18).rayDiv(0.434e27);
        assertApproxEqAbs(market.maxLiquidatable(), expected, 1e6, "formula");
        assertApproxEqAbs(market.maxLiquidatable(), 426_267281105990783410, 1e9); // 426.267...
        assertEq(market.recoverableDebt(), uint256(550e18).rayDiv(1.02e27));
        assertEq(market.unrecoverableDebt(), 0);

        uint256 max = market.maxLiquidatable();
        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, max);
        assertEq(repaid, max);
        assertApproxEqRel(slashed, repaid.rayMul(1.02e27), 1e12, "slashed = repaid*(1+b)");
        assertApproxEqRel(market.healthiness(), 1.25e27, 1e12, "lands on target health");
        emit log_named_decimal_uint("repaid          ", repaid, 18);
        emit log_named_decimal_uint("slashed (USD)   ", slashed, 18);
        emit log_named_decimal_uint("health after    ", market.healthiness(), 27);
    }

    /// The cap min(debt, recoverableDebt) binds exactly when health < (1+b)*lt = 0.816, which is
    /// the same condition as unrecoverableDebt > 0. Sweep price from 1.0 down to 0.05.
    function test_capBindsExactlyWhenUnrecoverable() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        uint256 threshold = uint256(1.02e27).rayMul(0.8e27); // 0.816e27
        for (uint256 p = 1e18; p >= 0.05e18; p -= 0.01e18) {
            _setPrice(address(collateral), p);
            uint256 h = market.healthiness();
            uint256 ml = market.maxLiquidatable();
            uint256 rec = market.recoverableDebt();
            uint256 debt = market.totalDebt();
            if (h >= 1e27) {
                assertEq(ml, 0);
                continue;
            }
            bool capBinds = ml == rec;
            bool unrec = market.unrecoverableDebt() > 0;
            // at h == threshold the three quantities coincide (ml == rec == debt), so the
            // equality case is where the cap begins to bind
            assertEq(capBinds, h <= threshold, "cap binds iff health <= (1+b)*lt");
            assertEq(unrec, h < threshold, "unrecoverable iff health < (1+b)*lt");
            if (unrec) assertLt(rec, debt, "when unrecoverable, debt exceeds recoverable");
        }
    }

    /// perCleared = targetHealth - (1+b)*lt cannot reach <= 0 inside the setter ranges
    /// (targetHealth >= 1.25, lt <= 1, b <= 0.1): worst case 1.25 - 1.1 = 0.15.
    function test_perClearedPositiveAtExtremes() public {
        irm.setLiquidationBonus(0.1e27);
        market.setLt(1e27);
        market.setTargetHealth(1.25e27);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.45e18); // TC 450, health 0.9
        // formula: (1.25*500 - 450)/(0.15) = 175/0.15 = 1166.7 > debt -> capped at min(debt, rec)
        uint256 ml = market.maxLiquidatable();
        assertEq(ml, market.recoverableDebt());
        assertGt(ml, 0);
        // setters refuse the values that would make perCleared <= 0
        vm.expectRevert(IBaseMarket.InvalidTargetHealth.selector);
        market.setTargetHealth(1.1e27);
        vm.expectRevert(IBaseMarket.InvalidLt.selector);
        market.setLt(1e27 + 1);
    }
}
