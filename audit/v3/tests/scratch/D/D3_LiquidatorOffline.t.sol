// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// WS-D item 2 (LIQUIDATOR liveness): liquidation is a single permissioned role. While it is
/// offline health keeps degrading (premium accrual + price) and no one else can act.
contract D3_LiquidatorOffline is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    address senior;
    address junior;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true; // base 5%, slope0 5%, slope1 10%, kink 0.8
        _deployCapWithConfig(cfg);
        (address m, address s, address j) = _createMarket("D3");
        market = FloatingMarket(m);
        senior = s;
        junior = j;
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        market.setUnderwriterRate(0.2e27);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, makeAddr("senior"), 500e18);
        _fundTranche(junior, makeAddr("junior"), 500e18);
        // idle reserve so utilization is ~50% rather than 100%
        _depositStable(makeAddr("lp"), 500e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
    }

    function test_nobodyElseCanLiquidate() public {
        _setPrice(address(collateral), 0.6e18); // health 0.96
        assertLt(market.healthiness(), 1e27);
        address[3] memory others = [defaultBorrower, makeAddr("senior"), makeAddr("mev")];
        for (uint256 i; i < 3; ++i) {
            _mintStable(others[i], 100e18);
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i]));
            market.liquidate(others[i], 100e18);
        }
        // the market owner, guardian, governor, keeper (this contract) cannot either
        _mintStable(address(this), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        market.liquidate(address(this), 100e18);
    }

    /// Health decay from premium accrual alone (no price move), and with a -1%/day price path.
    function test_healthDegradesWhileOffline() public {
        _setPrice(address(collateral), 0.63e18); // TC 630, health 1.008
        uint256 h0 = market.healthiness();
        emit log_named_decimal_uint("liquidity rate (ray)", irm.liquidityRate(), 27);
        emit log_named_decimal_uint("health t0            ", h0, 27);
        uint256[4] memory dts = [uint256(1 hours), 1 days, 7 days, 30 days];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            vm.revertToState(snap);
            skip(dts[i]);
            emit log_named_uint("  seconds offline", dts[i]);
            emit log_named_decimal_uint("  health (premium only)", market.healthiness(), 27);
            emit log_named_decimal_uint("  debt", market.totalDebt(), 18);
        }
        vm.revertToState(snap);
        // price path: -1%/day from 0.63 for 30 days; anyone can poke chargePremium so the accrual
        // is realised on-chain, and it is not needed for the health view anyway
        uint256 p = 0.63e18;
        for (uint256 d = 1; d <= 30; ++d) {
            skip(1 days);
            p = p * 99 / 100;
            p -= p % 1e10;
            _setPrice(address(collateral), p);
            vm.prank(makeAddr("anyone"));
            market.chargePremium();
            if (d == 1 || d == 7 || d == 14 || d == 21 || d == 30) {
                emit log_named_uint("day", d);
                emit log_named_decimal_uint("  health", market.healthiness(), 27);
                emit log_named_decimal_uint("  unrecoverableDebt", market.unrecoverableDebt(), 18);
            }
        }
        assertGt(market.unrecoverableDebt(), 0, "insolvent after ~3 weeks of -1%/day with no liquidator");
    }
}
