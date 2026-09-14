// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MathUtils } from "../../../contracts/utils/MathUtils.sol";
import { WadRayMath } from "../../../contracts/utils/WadRayMath.sol";
import { Test } from "forge-std/Test.sol";

contract MathUtilsHarness {
    function linear(uint256 rate, uint256 lastUpdate) external view returns (uint256) {
        return MathUtils.calculateLinearInterest(rate, lastUpdate);
    }

    function compounded(uint256 rate, uint256 lastUpdate) external view returns (uint256) {
        return MathUtils.calculateCompoundedInterest(rate, lastUpdate);
    }

    function compoundedAt(uint256 rate, uint256 last, uint256 current) external pure returns (uint256) {
        return MathUtils.calculateCompoundedInterest(rate, last, current);
    }
}

contract MathUtilsTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR = 365 days;

    MathUtilsHarness internal m;

    function setUp() public {
        m = new MathUtilsHarness();
    }

    function test_linear_zeroElapsed_isRay() public view {
        assertEq(m.linear(RAY, block.timestamp), RAY);
    }

    function test_linear_oneYear() public {
        uint256 start = block.timestamp;
        vm.warp(start + YEAR);
        // 10% APR linear over a year -> 1.1 ray
        assertEq(m.linear(0.1e27, start), RAY + 0.1e27);
    }

    function test_compounded_zeroElapsed_isRay() public view {
        assertEq(m.compoundedAt(0.1e27, 100, 100), RAY);
    }

    function test_compounded_geLinear() public {
        uint256 start = block.timestamp;
        vm.warp(start + YEAR);
        uint256 rate = 0.2e27;
        uint256 lin = m.linear(rate, start);
        uint256 comp = m.compounded(rate, start);
        // compounding accrues at least as much as linear over a positive interval
        assertGe(comp, lin);
    }

    function test_compounded_zeroRate_isRay() public {
        uint256 start = block.timestamp;
        vm.warp(start + 30 days);
        assertEq(m.compounded(0, start), RAY);
    }

    function testFuzz_compounded_monotonic_inTime(uint32 t1, uint32 t2) public view {
        vm.assume(t2 > t1);
        uint256 rate = 0.05e27;
        uint256 a = m.compoundedAt(rate, 0, t1);
        uint256 b = m.compoundedAt(rate, 0, t2);
        assertGe(b, a);
    }

    /// @dev A single cubic over five years at 100% under-accrues by ~73%. Year-sized windows
    /// recover the one-year cubic folded five times, which is what annual checkpoints would pay.
    function test_compounded_fiveYearsEqualsFiveAnnualWindows() public view {
        uint256 rate = RAY;
        uint256 one = m.compoundedAt(rate, 0, YEAR);
        uint256 folded = RAY;
        for (uint256 i; i < 5; ++i) {
            folded = WadRayMath.rayMul(folded, one);
        }
        assertEq(m.compoundedAt(rate, 0, 5 * YEAR), folded);
    }

    /// @dev The old single-checkpoint cubic at 5 y / 100% lands near 40 ray; e^5 is ~148.
    /// Year windows land on (8/3)^5 ≈ 135, so the gap stays at the one-year bound.
    function test_compounded_fiveYearsDoesNotCollapseOntoASingleCubic() public view {
        uint256 rate = RAY;
        uint256 chunked = m.compoundedAt(rate, 0, 5 * YEAR);
        uint256 single = _singleCubic(rate, 5 * YEAR);
        assertGt(chunked, single * 3, "year windows pay several times the single cubic");
        assertApproxEqRel(chunked, WadRayMath.rayExp(5 * RAY), 0.1e18, "within ~10% of e^5");
    }

    function _singleCubic(uint256 rate, uint256 exp) private pure returns (uint256 interestRate) {
        uint256 expMinusOne = exp - 1;
        uint256 expMinusTwo = exp > 2 ? exp - 2 : 0;
        uint256 basePowerTwo = WadRayMath.rayMul(rate, rate) / (YEAR * YEAR);
        uint256 basePowerThree = WadRayMath.rayMul(basePowerTwo, rate) / YEAR;
        uint256 secondTerm = exp * expMinusOne * basePowerTwo / 2;
        uint256 thirdTerm = exp * expMinusOne * expMinusTwo * basePowerThree / 6;
        interestRate = RAY + (rate * exp) / YEAR + secondTerm + thirdTerm;
    }
}
