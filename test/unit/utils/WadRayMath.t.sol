// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { WadRayMath } from "../../../contracts/utils/WadRayMath.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Exposes the internal library functions for external calls
contract WadRayMathHarness {
    function rayMul(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayMul(a, b);
    }

    function rayDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayDiv(a, b);
    }

    function wadMul(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.wadMul(a, b);
    }

    function wadDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.wadDiv(a, b);
    }

    function rayToWad(uint256 a) external pure returns (uint256) {
        return WadRayMath.rayToWad(a);
    }

    function wadToRay(uint256 a) external pure returns (uint256) {
        return WadRayMath.wadToRay(a);
    }

    function rayPow(uint256 a, uint256 n) external pure returns (uint256) {
        return WadRayMath.rayPow(a, n);
    }
}

contract WadRayMathTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_RAY = 0.5e27;
    uint256 internal constant HALF_WAD = 0.5e18;

    WadRayMathHarness internal m;

    function setUp() public {
        m = new WadRayMathHarness();
    }

    function test_rayMul_identity() public view {
        assertEq(m.rayMul(5 * RAY, RAY), 5 * RAY);
        assertEq(m.rayMul(RAY, 7 * RAY), 7 * RAY);
    }

    function test_rayMul_zero() public view {
        assertEq(m.rayMul(0, RAY), 0);
        assertEq(m.rayMul(RAY, 0), 0);
    }

    function test_rayMul_roundsHalfUp() public view {
        // 1 * 1 (in ray) = 1e-54, rounds to 0; but (HALF_RAY worth) rounds up
        assertEq(m.rayMul(2, HALF_RAY), 1); // 2 * 0.5e27 = 1e27 -> /RAY = 1 after +HALF_RAY
    }

    function test_rayDiv_identity() public view {
        assertEq(m.rayDiv(5 * RAY, RAY), 5 * RAY);
    }

    function test_rayDiv_byZero_reverts() public {
        vm.expectRevert();
        m.rayDiv(RAY, 0);
    }

    function test_rayMul_overflow_reverts() public {
        vm.expectRevert();
        m.rayMul(type(uint256).max, 2 * RAY);
    }

    function test_wadMul_identity() public view {
        assertEq(m.wadMul(5 * WAD, WAD), 5 * WAD);
    }

    function test_wadDiv_byZero_reverts() public {
        vm.expectRevert();
        m.wadDiv(WAD, 0);
    }

    function test_wadDiv_identity() public view {
        assertEq(m.wadDiv(5 * WAD, WAD), 5 * WAD);
        assertEq(m.wadDiv(WAD, WAD), WAD);
    }

    function test_wadMul_zero() public view {
        assertEq(m.wadMul(0, WAD), 0);
        assertEq(m.wadMul(WAD, 0), 0);
    }

    function test_wadMul_overflow_reverts() public {
        vm.expectRevert();
        m.wadMul(type(uint256).max, 2 * WAD);
    }

    function test_wadDiv_overflow_reverts() public {
        vm.expectRevert();
        m.wadDiv(type(uint256).max, 1);
    }

    function test_wadToRay_overflow_reverts() public {
        vm.expectRevert();
        m.wadToRay(type(uint256).max);
    }

    function test_rayToWad_roundsHalfUp() public view {
        assertEq(m.rayToWad(RAY), WAD);
        // 1.5e9 in ray remainder -> rounds up
        assertEq(m.rayToWad(1.5e9), 2);
        assertEq(m.rayToWad(1.4e9), 1);
    }

    function test_wadToRay_roundtrip() public view {
        assertEq(m.wadToRay(WAD), RAY);
        assertEq(m.rayToWad(m.wadToRay(12345 * WAD)), 12345 * WAD);
    }

    function testFuzz_rayMul_commutative(uint128 a, uint128 b) public view {
        assertEq(m.rayMul(a, b), m.rayMul(b, a));
    }

    // ── rayPow ────────────────────────────────────────────────────────────────

    function test_rayPow_zeroExponentIsOne() public view {
        assertEq(m.rayPow(0.5e27, 0), RAY, "anything to the zero is one ray");
    }

    function test_rayPow_oneExponentIsTheBase() public view {
        assertEq(m.rayPow(0.5e27, 1), 0.5e27);
    }

    /// @dev The property {IInterestRateModel-averagingPeriod} depends on, and the reason this
    /// exists rather than a loop of {rayMul}: splitting an exponent must not change the result, so
    /// a decay applied across an interval matches the same decay applied across its parts.
    function testFuzz_rayPow_exponentsAdd(uint8 m1, uint8 n1) public view {
        uint256 base = 0.999e27;
        assertApproxEqAbs(
            m.rayMul(m.rayPow(base, m1), m.rayPow(base, n1)),
            m.rayPow(base, uint256(m1) + n1),
            10,
            "a^m raymul a^n has to be a^(m+n), give or take the half-up rounding in each step"
        );
    }

    function test_rayPow_decaysMonotonically() public view {
        uint256 base = 0.9e27;
        uint256 previous = RAY;
        for (uint256 n = 1; n <= 20; ++n) {
            uint256 current = m.rayPow(base, n);
            assertLt(current, previous, "a base under one ray only shrinks");
            previous = current;
        }
    }

    /// @dev Squaring the base on the final iteration would be thrown away, and for a base this
    /// far above one ray it overflows {rayMul} on the way to being thrown away. Nothing in the
    /// protocol raises a base above one, but a library that reverts on an answer it already holds
    /// is a trap for whatever calls it next.
    function test_rayPow_doesNotSquareTheBaseItNoLongerNeeds() public view {
        uint256 enormous = 1e40;
        assertEq(m.rayPow(enormous, 1), enormous, "the answer was already in hand");
    }

    function test_rayPow_largeExponentRunsInLogTime() public view {
        // 0.999^100000 has long since underflowed the ray, and getting there must not need
        // 100000 multiplications
        assertEq(m.rayPow(0.999e27, 100_000), 0, "decayed past the smallest representable ray");
    }

    function testFuzz_rayMul_identity(uint128 a) public view {
        assertEq(m.rayMul(a, RAY), a);
    }

    function testFuzz_rayDiv_identity(uint128 a) public view {
        assertEq(m.rayDiv(a, RAY), a);
    }

    function testFuzz_rayDiv_then_rayMul_approx(uint64 a, uint32 b) public view {
        b = uint32(bound(b, 1, 1e6));
        uint256 q = m.rayDiv(uint256(a) * RAY, uint256(b) * RAY);
        // (a/b)*b ~= a; rounding error of rayDiv is < 1 ray, amplified by the multiplier b
        uint256 back = m.rayMul(q, uint256(b) * RAY);
        assertApproxEqAbs(back, uint256(a) * RAY, (uint256(b) + 1) * RAY);
    }
}
