// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test } from "forge-std/Test.sol";

/// @notice I22 / L-17: rayPow accuracy vs a 36-digit reference, EMA path-independence, gas.
contract N4_RayPow is Test {
    using WadRayMath for uint256;

    uint256 constant RAY = 1e27;
    uint256 constant P36 = 1e36;

    /// 36-digit square-and-multiply, floor at every step (error ≤ ~2·log2(n) ulp at 1e-36)
    function _ref36(uint256 a27, uint256 n) internal pure returns (uint256 c) {
        uint256 a = a27 * 1e9;
        c = P36;
        while (n > 0) {
            if (n & 1 == 1) c = Math.mulDiv(c, a, P36);
            n >>= 1;
            if (n > 0) a = Math.mulDiv(a, a, P36);
        }
    }

    // ── accuracy: retention bases for every allowed period, n up to 10 years ──
    function testFuzz_rayPowAccuracy(uint32 period, uint32 n) public pure {
        period = uint32(bound(period, 5 minutes, 1 days));
        n = uint32(bound(n, 1, 315_360_000)); // 10 years
        uint256 r = RAY - RAY / period;
        uint256 got = r.rayPow(n);
        uint256 ref = _ref36(r, n) / 1e9;
        // each squaring doubles the accumulated relative rounding error, so the bound is O(n) ulp
        // in ray (observed: 1713 ulp at n = 28013), i.e. ≤ 3e8 ulp = 3e-19 absolute at 10 years
        uint256 diff = got > ref ? got - ref : ref - got;
        assertLe(diff, uint256(n) + 64, "rayPow error exceeds n + 64 ulp");
        assertLe(diff, 1e9, "rayPow absolute error exceeds 1e-18");
    }

    /// arbitrary base ≤ RAY: never reverts, never exceeds RAY, monotone in n
    function testFuzz_rayPowBoundedAndMonotone(uint256 a, uint32 n) public pure {
        a = bound(a, 0, RAY);
        n = uint32(bound(n, 1, 315_360_000));
        uint256 c = a.rayPow(n);
        assertLe(c, RAY);
        assertLe(c, a);
        assertGe(c, a.rayPow(uint256(n) + 1));
    }

    /// early-underflow check: for the smallest retention (5 min period) where does r^n hit 0?
    function test_rayPowUnderflowPoint() public pure {
        uint256 r = RAY - RAY / 5 minutes;
        // r^n = 0 iff n ≥ ~ ln(1e27)/ (1/300) ≈ 18,650 in exact arithmetic
        uint256 nZero;
        for (uint256 n = 18_000; n < 20_000; n += 10) {
            if (r.rayPow(n) == 0) {
                nZero = n;
                break;
            }
        }
        assertGt(nZero, 18_000);
        // and no value below the exact cross-over collapses early: r^(18000) should be non-zero
        assertGt(r.rayPow(18_000), 0);
        // the largest period: 1 day, 10 years → exact value e^-3650 = 0
        assertEq((RAY - RAY / 1 days).rayPow(315_360_000), 0);
    }

    function test_rayPowGas10Years() public {
        uint256 r = RAY - RAY / 1 days;
        uint256 g = gasleft();
        r.rayPow(315_360_000);
        emit log_named_uint("gas rayPow(r, 3e8)", g - gasleft());
    }

    // ── I22: EMA path-independence with k splits (formulas copied from IRM verbatim) ──
    function _weight(uint256 retention, uint256 elapsed) internal pure returns (uint256) {
        return RAY - retention.rayPow(elapsed);
    }

    function _carry(uint256 average, uint256 observed, uint256 weight) internal pure returns (uint256) {
        return observed > average
            ? average + (observed - average).rayMul(weight)
            : average - (average - observed).rayMul(weight);
    }

    function testFuzz_I22_emaPathIndependent(
        uint32 period,
        uint32 elapsed,
        uint8 k,
        uint128 avg0,
        uint128 observed,
        uint256 seed
    ) public pure {
        period = uint32(bound(period, 5 minutes, 1 days));
        elapsed = uint32(bound(elapsed, 1, 10 days));
        k = uint8(bound(k, 1, 200));
        if (k > elapsed) k = uint8(elapsed);
        uint256 r = RAY - RAY / period;

        uint256 oneShot = _carry(avg0, observed, _weight(r, elapsed));

        // split elapsed into k random positive pieces
        uint256 avg = avg0;
        uint256 left = elapsed;
        for (uint256 i = 0; i < k; ++i) {
            uint256 piece;
            if (i == k - 1) {
                piece = left;
            } else {
                uint256 maxPiece = left - (k - 1 - i); // leave ≥1 for each remaining split
                piece = 1 + (uint256(keccak256(abi.encode(seed, i))) % maxPiece);
            }
            avg = _carry(avg, observed, _weight(r, piece));
            left -= piece;
        }
        uint256 diff = avg > oneShot ? avg - oneShot : oneShot - avg;
        uint256 gap = observed > avg0 ? observed - avg0 : avg0 - observed;
        // tolerance: k half-up roundings of (gap * weight) at 1e-27 relative each, plus rayPow ulps
        // rayPow itself carries O(elapsed) ulp of error, scaled by the gap
        uint256 tol = 1 + (uint256(k) + uint256(elapsed) + 64) * (gap / RAY + 1);
        assertLe(diff, tol, "EMA depends on the accrual path");
    }
}
