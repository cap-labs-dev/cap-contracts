// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { WadRayMath } from "./WadRayMath.sol";

/// @title MathUtils library
/// @author Aave
/// @notice Provides functions to perform linear and compounded interest calculations
library MathUtils {
    using WadRayMath for uint256;

    /// @dev Ignoring leap years
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev Function to calculate the interest accumulated using a linear interest rate formula
    /// @param rate The interest rate, in ray
    /// @param lastUpdateTimestamp The timestamp of the last update of the interest
    /// @return interestRate The interest rate linearly accumulated during the timeDelta, in ray
    function calculateLinearInterest(uint256 rate, uint256 lastUpdateTimestamp)
        internal
        view
        returns (uint256 interestRate)
    {
        //solium-disable-next-line
        uint256 result = rate * (block.timestamp - lastUpdateTimestamp);
        unchecked {
            result = result / SECONDS_PER_YEAR;
        }

        interestRate = WadRayMath.RAY + result;
    }

    /// @dev Compound `rate` from `lastUpdateTimestamp` to `currentTimestamp`.
    /// Each window of at most one year uses Aave's cubic binomial. A single cubic over many
    /// years under-accrues without bound (about 1.9% after 1 y at 100%, 73% after 5 y). Folding
    /// year-sized windows keeps the error at the one-year bound, and matches checkpointing once
    /// a year. The underwriter index is only written on a rate change, so the view has to do
    /// this itself.
    /// @param rate The interest rate, in ray
    /// @param lastUpdateTimestamp The timestamp of the last update of the interest
    /// @param currentTimestamp The timestamp to accumulate interest up to
    /// @return interestRate The interest rate compounded during the timeDelta, in ray
    function calculateCompoundedInterest(uint256 rate, uint256 lastUpdateTimestamp, uint256 currentTimestamp)
        internal
        pure
        returns (uint256 interestRate)
    {
        //solium-disable-next-line
        uint256 exp = currentTimestamp - lastUpdateTimestamp;
        if (exp == 0) return WadRayMath.RAY;

        interestRate = WadRayMath.RAY;
        while (exp > 0) {
            uint256 step = exp > SECONDS_PER_YEAR ? SECONDS_PER_YEAR : exp;
            interestRate = interestRate.rayMul(_compoundedInterest(rate, step));
            unchecked {
                exp -= step;
            }
        }
    }

    /// @dev Cubic binomial for a single window. `exp` must be positive and is intended to be at
    /// most {SECONDS_PER_YEAR}.
    /// @param rate The interest rate, in ray
    /// @param exp Elapsed seconds in this window
    /// @return interestRate The growth factor for this window, in ray
    function _compoundedInterest(uint256 rate, uint256 exp) private pure returns (uint256 interestRate) {
        uint256 expMinusOne;
        uint256 expMinusTwo;
        uint256 basePowerTwo;
        uint256 basePowerThree;
        unchecked {
            expMinusOne = exp - 1;
            expMinusTwo = exp > 2 ? exp - 2 : 0;
            basePowerTwo = rate.rayMul(rate) / (SECONDS_PER_YEAR * SECONDS_PER_YEAR);
            basePowerThree = basePowerTwo.rayMul(rate) / SECONDS_PER_YEAR;
        }

        uint256 secondTerm = exp * expMinusOne * basePowerTwo;
        unchecked {
            secondTerm /= 2;
        }
        uint256 thirdTerm = exp * expMinusOne * expMinusTwo * basePowerThree;
        unchecked {
            thirdTerm /= 6;
        }

        interestRate = WadRayMath.RAY + (rate * exp) / SECONDS_PER_YEAR + secondTerm + thirdTerm;
    }

    /// @dev Calculates the compounded interest between the timestamp of the last update and the current block timestamp
    /// @param rate The interest rate (in ray)
    /// @param lastUpdateTimestamp The timestamp from which the interest accumulation needs to be calculated
    /// @return interestRate The interest rate compounded between lastUpdateTimestamp and current block timestamp, in ray
    function calculateCompoundedInterest(uint256 rate, uint256 lastUpdateTimestamp)
        internal
        view
        returns (uint256 interestRate)
    {
        interestRate = calculateCompoundedInterest(rate, lastUpdateTimestamp, block.timestamp);
    }
}
