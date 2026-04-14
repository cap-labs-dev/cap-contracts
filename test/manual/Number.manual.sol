// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

/// @dev Manual scratchpad for checking rounding/precision math.
/// Intentionally contains no `test*` functions so it never runs in CI.
contract NumberManual is Test {
    function manual_numbers() public pure {
        uint256 liquidatedRequestAmount = 2600e8;
        uint256 price = 2600e8;
        uint256 ethInTheDelegator = 30e18;

        // Because of rounding at delegator level there is 1 less share
        uint256 ethInTheDelegatorValue = ((ethInTheDelegator * price) / 1e18) - 1;
        uint256 precision = (liquidatedRequestAmount * 1e18) / ethInTheDelegatorValue;
        uint256 liquidated = (ethInTheDelegator * precision) / 1e18;

        // Silence "unused" warnings while keeping the calculations.
        (liquidatedRequestAmount, price, ethInTheDelegator, ethInTheDelegatorValue, precision, liquidated);
    }
}

