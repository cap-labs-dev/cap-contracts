// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Math helper
/// @notice Helper functions for math operations
library MathHelper {
    /// @notice Thrown when there are no real roots
    error NoRealRoots();

    /// @notice Solve quadratic equation ax^2 + bx + c = 0 for real roots using the quadratic formula
    /// @dev y = (-b ± sqrt(b^2 - 4ac)) / (2a)
    /// Returns roots sorted ascending. If a==0, degenerates to linear (bx + c = 0)
    /// @param a The coefficient of the quadratic term
    /// @param b The coefficient of the linear term
    /// @param c The constant term
    /// @return r1 The first root
    /// @return r2 The second root
    function quadratic(int256 a, int256 b, int256 c) external pure returns (int256 r1, int256 r2) {
        // Linear case
        if (a == 0) {
            if (b == 0) revert NoRealRoots();
            int256 x = -c / b;
            return (x, x);
        }

        // Discriminant: D = b^2 - 4ac
        int256 d = b * b - (4 * a * c);
        if (d < 0) revert NoRealRoots();

        int256 sqrtD = int256(Math.sqrt(uint256(d)));

        int256 twoA = 2 * a;

        r1 = (-b - sqrtD) / twoA;
        r2 = (-b + sqrtD) / twoA;

        // Sort roots ascending
        if (r2 < r1) (r1, r2) = (r2, r1);
    }
}
