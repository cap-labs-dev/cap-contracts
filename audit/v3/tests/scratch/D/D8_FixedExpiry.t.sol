// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../../../../contracts/interfaces/IFixedMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// WS-D item 7: an expired, unpaid fixed loan on a healthy market cannot be liquidated. Only
/// KEEPER extendAdmin (after grace) charges arrears; health only crosses 1 by premium accrual.
contract D8_FixedExpiry is CapDeployer {
    using WadRayMath for uint256;

    function _market(bool slopes, uint256 uwRate) internal returns (FixedMarket fm, uint256 id) {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = slopes;
        _deployCapWithConfig(cfg);
        (address m, address s,) = _createFixedMarket("D8");
        fm = FixedMarket(m);
        if (slopes) irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        fm.setUnderwriterRate(uwRate);
        fm.setLtv(0.7e27); // max: ltv + buffer <= lt
        fm.setFixedCreditLimit(1_000_000e18);
        _fundTranche(s, makeAddr("s"), 1_000e18);
        if (slopes) _depositStable(makeAddr("lp"), 1_000e18); // ~40% utilization
        vm.prank(defaultBorrower);
        (id,) = fm.borrow(defaultBorrower, type(uint256).max, 30 days);
    }

    function _timeline(FixedMarket fm, uint256 id) internal returns (uint256 daysUntilLiquidatable) {
        uint256 t0 = block.timestamp;
        emit log_named_decimal_uint("debt at borrow            ", fm.debt(id), 18);
        emit log_named_decimal_uint("health at borrow          ", fm.healthiness(), 27);
        // expiry passes; the loan is in default but the market is healthy
        vm.warp(fm.expiry(id) + 1);
        assertGe(fm.healthiness(), 1e27);
        _mintStable(defaultLiquidator, 1_000e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        fm.liquidate(id, defaultLiquidator, 100e18);
        // inside grace the keeper cannot act either
        vm.expectRevert(IFixedMarket.StillInGracePeriod.selector);
        fm.extendAdmin(id, 30 days);

        uint256 n;
        while (fm.healthiness() >= 1e27) {
            vm.warp(fm.expiry(id) + fm.grace() + 1);
            fm.extendAdmin(id, 30 days); // KEEPER: arrears (grace+1s) + 30d of premium
            ++n;
            if (n > 400) break;
        }
        daysUntilLiquidatable = (block.timestamp - t0) / 1 days;
        emit log_named_uint("extendAdmin calls          ", n);
        emit log_named_uint("days from borrow to h < 1  ", daysUntilLiquidatable);
        emit log_named_decimal_uint("debt when liquidatable    ", fm.debt(id), 18);
        emit log_named_decimal_uint("health                    ", fm.healthiness(), 27);
        assertLt(fm.healthiness(), 1e27);
        uint256 max = fm.maxLiquidatable();
        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = fm.liquidate(id, defaultLiquidator, max);
        assertGt(repaid, 0);
    }

    /// Deploy defaults: no liquidity slopes set (liquidity rate 0), underwriter rate 20%.
    function test_timeline_deployDefaults_uw20() public {
        (FixedMarket fm, uint256 id) = _market(false, 0.2e27);
        _timeline(fm, id);
    }

    /// Test-harness slopes (5/5/10 kink 0.8) at ~40% utilization plus underwriter 20%.
    function test_timeline_withLiquiditySlopes_uw20() public {
        (FixedMarket fm, uint256 id) = _market(true, 0.2e27);
        emit log_named_decimal_uint("liquidity rate", irm.liquidityRate(), 27);
        _timeline(fm, id);
    }

    /// Underwriter rate 5% and no slopes: the borrower's default goes unenforced for years.
    function test_timeline_uw5() public {
        (FixedMarket fm, uint256 id) = _market(false, 0.05e27);
        _timeline(fm, id);
    }

    /// Repay is permissionless and carries no penalty beyond the extension premium.
    function test_lateRepayHasNoPenalty() public {
        (FixedMarket fm, uint256 id) = _market(false, 0.2e27);
        vm.warp(fm.expiry(id) + 365 days);
        uint256 debt = fm.debt(id);
        _mintStable(defaultBorrower, debt);
        vm.prank(defaultBorrower);
        fm.repay(id, type(uint256).max);
        assertEq(fm.debt(id), 0);
        emit log_named_decimal_uint("debt repaid a year late (no extendAdmin ran)", debt, 18);
    }
}
