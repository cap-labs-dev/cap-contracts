// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { MathUtils } from "../../../../contracts/utils/MathUtils.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice E-5 (H8) and E-6 (EMA regime): governance-range vs safe-range for the rate curve, and
/// the averaging window meaning two different things depending on how busy the stablecoin is.
contract E4_IrmBounds is CapDeployer {
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _depositStable(lp, 1_000_000e18);
        _mintStable(makeAddr("b"), 500_000e18); // 50% utilization
    }

    /// @dev H8: `setLiquiditySlopes` accepts any base. Past ~8.8e7 ray-years of rate x time the
    /// index product overflows `rayMul`, and because every stablecoin supply move AND the slopes
    /// setter itself accrue first, nothing short of an upgrade can move the protocol again.
    function test_H8_unboundedBaseBricksStablecoinAndSetterCannotRecover() public {
        IInterestRateModel.Slopes memory insane =
            IInterestRateModel.Slopes({ base: 1e37, slope0: 0, slope1: 0, kink: 0.8e27 }); // 1e10 x 100% APR
        irm.setLiquiditySlopes(insane);
        skip(30 days); // x = 1e10 * 30/365 = 8.2e8 > 8.8e7 threshold

        // every supply move is dead
        cusdUnderlying.mint(lp, 1e18);
        vm.startPrank(lp);
        cusdUnderlying.approve(address(stablecoin), 1e18);
        (bool ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.deposit, (1e18, lp)));
        vm.stopPrank();
        assertFalse(ok, "deposit reverts: index overflow");
        (ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.mintCreditBacked, (lp, 1e18)));
        assertFalse(ok, "borrowing (mintCreditBacked) reverts: index overflow");

        // and governance cannot back out: the setter accrues before it sets
        IInterestRateModel.Slopes memory sane = capConfig.liquiditySlopes;
        (ok,) = address(irm).call(abi.encodeCall(irm.setLiquiditySlopes, (sane)));
        assertTrue(ok, "setLiquiditySlopes must be able to recover from a bad curve");
    }

    /// @dev Numeric threshold for the above, printed for the report
    function test_H8_overflowThreshold() public pure {
        // index (1e27) * compounded must stay under 2^256 - HALF_RAY / ... : compounded < ~1.16e50
        // compounded = 1e27 * (1 + x + x^2/2 + x^3/6); x^3/6 dominates: x < (6 * 1.16e23)^(1/3) ~ 8.8e7
        uint256 rate = 1e36; // 1e9 x 100% APR
        uint256 ok = MathUtils.calculateCompoundedInterest(rate, 0, 30 days); // x = 8.2e7, fits
        require(ok > 0);
        // 33 days at the same rate: x = 9.04e7 -> compounded ~ 1.23e50, rayMul(1e27, that) reverts
    }

    /// @dev EMA regime dependence: the same deposit, held for exactly one averaging period, is
    /// weighted 100% if the stablecoin is quiet and ~63% if someone accrues every block. The
    /// "averaging period" is a snap interval in one regime and an exponential time constant in
    /// the other, and any party can choose the regime by spamming the permissionless
    /// `updateLiquidityRate`.
    function test_EMA_weightDependsOnAccrualFrequency() public {
        uint256 period = irm.averagingPeriod();
        skip(period); // settle: avg = (500k, 1M)
        (, uint256 s0) = irm.averageSupplies();
        assertEq(s0, 1_500_000e18); // 1M deposited + 500k credit-backed

        uint256 snap = vm.snapshotState();
        _depositStable(makeAddr("d"), 1_000_000e18); // observed supply -> 2M
        skip(period);
        (, uint256 quietSupply) = irm.averageSupplies();
        vm.revertToState(snap);

        _depositStable(makeAddr("d"), 1_000_000e18);
        uint256 steps = period / 12;
        for (uint256 i; i < steps; ++i) {
            skip(12);
            irm.updateLiquidityRate(); // permissionless
        }
        (, uint256 busySupply) = irm.averageSupplies();

        emit log_named_decimal_uint("avg supply after one period, quiet", quietSupply, 18);
        emit log_named_decimal_uint("avg supply after one period, accrual every 12s", busySupply, 18);
        emit log_named_uint("quiet: % of the way to the new observation", (quietSupply - s0) * 100 / 1_000_000e18);
        emit log_named_uint("busy:  % of the way to the new observation", (busySupply - s0) * 100 / 1_000_000e18);
        assertEq(
            busySupply, quietSupply, "one averaging period should weight an observation the same regardless of activity"
        );
    }

    /// @dev Binomial 3-term compounding vs the exact exponential, for the modelling section
    function test_compoundingApproximationError() public {
        // 50% APR, 30 days: x = 0.5 * 30/365 = 0.0410959; exact e^x = 1.04195201...
        emit log_named_uint("50% APR, 30d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(0.5e27, 0, 30 days));
        emit log_named_uint("50% APR, 30d unaccrued: exact ", 1041952014e18);
        // 100% APR, 365 days unaccrued: exact e = 2.718281828; 3-term = 2.6666...
        emit log_named_uint(
            "100% APR, 365d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(1e27, 0, 365 days)
        );
        emit log_named_uint("100% APR, 365d unaccrued: exact ", 2718281828e18);
        // 20% APR, 1 day (a realistic accrual gap)
        emit log_named_uint("20% APR, 1d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(0.2e27, 0, 1 days));
        emit log_named_uint("20% APR, 1d unaccrued: exact ", 1000548095e18);
    }
}
