// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// L-6 (round 2): liquidity slopes are unbounded (only `kink <= 1e27` is checked). A base rate
// large enough that rate*time overflows `calculateCompoundedInterest` bricks every accruing path,
// and `setLiquiditySlopes` accrues before writing, so the governor cannot repair it either.
// Port of round-1 E4 (H8 tests + compounding-approximation log).
import { IInterestRateModel } from "../../../../../../contracts/interfaces/IInterestRateModel.sol";
import { MathUtils } from "../../../../../../contracts/utils/MathUtils.sol";
import { WadRayMath } from "../../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

contract L6_IrmBounds is CapDeployer {
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _depositStable(lp, 1_000_000e18);
        _mintStable(makeAddr("b"), 500_000e18); // 50% utilization
    }

    function test_H8_unboundedBaseBricksStablecoinAndSetterCannotRecover() public {
        IInterestRateModel.Slopes memory insane =
            IInterestRateModel.Slopes({ base: 1e37, slope0: 0, slope1: 0, kink: 0.8e27 }); // 1e10 x 100% APR
        irm.setLiquiditySlopes(insane); // accepted: no bound on base/slope0/slope1
        emit log_named_uint("liquidityRate accepted (ray/yr)", irm.liquidityRate());

        skip(30 days); // x = 1e10 * 30/365 = 8.2e8 > ~8.8e7 threshold

        (bool ok,) = address(irm).staticcall(abi.encodeCall(irm.liquidityIndex, (address(this))));
        assertFalse(ok, "liquidityIndex view reverts: index overflow");

        cusdUnderlying.mint(lp, 1e18);
        vm.startPrank(lp);
        cusdUnderlying.approve(address(stablecoin), 1e18);
        (ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.deposit, (1e18, lp)));
        vm.stopPrank();
        assertFalse(ok, "deposit reverts: index overflow");

        (ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.mintCreditBacked, (lp, 1e18)));
        assertFalse(ok, "borrowing (mintCreditBacked) reverts: index overflow");

        IInterestRateModel.Slopes memory sane = capConfig.liquiditySlopes;
        (ok,) = address(irm).call(abi.encodeCall(irm.setLiquiditySlopes, (sane)));
        emit log_named_string("setLiquiditySlopes(sane) after 30d", ok ? "ok" : "REVERTS");
        assertTrue(ok, "setLiquiditySlopes must be able to recover from a bad curve");
    }

    function test_H8_overflowThreshold() public pure {
        uint256 rate = 1e36; // 1e9 x 100% APR
        uint256 ok = MathUtils.calculateCompoundedInterest(rate, 0, 30 days); // x = 8.2e7, fits
        require(ok > 0);
    }

    function test_H8_overflowThresholdExceeded() public {
        uint256 rate = 1e37; // 1e10 x 100% APR
        (bool ok,) = address(this).call(abi.encodeCall(this.compound, (rate, 30 days)));
        assertFalse(ok, "x = 8.2e8: index.rayMul(3-term expansion) overflows rayMul");
    }

    /// @dev mirrors `_index`: index.rayMul(compounded) -- the rayMul overflow guard is what reverts
    function compound(uint256 rate, uint256 dt) external pure returns (uint256) {
        return WadRayMath.rayMul(1e27, MathUtils.calculateCompoundedInterest(rate, 0, dt));
    }

    function test_compoundingApproximationError() public {
        emit log_named_uint("50% APR, 30d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(0.5e27, 0, 30 days));
        emit log_named_uint("50% APR, 30d unaccrued: exact ", 1041952014e18);
        emit log_named_uint(
            "100% APR, 365d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(1e27, 0, 365 days)
        );
        emit log_named_uint("100% APR, 365d unaccrued: exact ", 2718281828e18);
        emit log_named_uint("20% APR, 1d unaccrued: 3-term", MathUtils.calculateCompoundedInterest(0.2e27, 0, 1 days));
        emit log_named_uint("20% APR, 1d unaccrued: exact ", 1000548095e18);
    }
}
