// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract NumberTest is Test {
    function setUp() public { }

    function test_numbers() public pure {
        uint256 liquidatedRequestAmount = 2600e8;
        console.log("Liquidated Request Amount", liquidatedRequestAmount);

        uint256 price = 2600e8;
        console.log("Price", price);

        uint256 ethInTheDelegator = 30e18;
        console.log("Eth In The Delegator", ethInTheDelegator);

        // Because of rounding at delegator level there is 1 less share
        uint256 ethInTheDelegatorValue = ((ethInTheDelegator * price) / 1e18) - 1;
        console.log("ethInTheDelegatorValue", ethInTheDelegatorValue);

        uint256 precision = (liquidatedRequestAmount * 1e18) / ethInTheDelegatorValue;
        console.log("Share Precision", precision);

        uint256 liquidated = (ethInTheDelegator * precision) / 1e18;
        console.log("Liquidated with precision", liquidated);
        console.log("Liquidated value", (liquidated * price / 1e8));

        console.log("");

        console.log("/////Rounded First/////");

        uint256 roundedPrecision = liquidatedRequestAmount * 1e8 / ethInTheDelegatorValue;
        console.log("Rounded Precision", roundedPrecision);

        precision = roundedPrecision * 1e10;
        console.log("Share Precision", precision);
        liquidated = (ethInTheDelegator * precision) / 1e18;
        console.log("Liquidated with rounded precision", liquidated);
        console.log("Liquidated value with rounded precision", (liquidated * price / 1e8));
    }
}
