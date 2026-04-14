// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";

import { OracleFixture } from "../fixtures/OracleFixture.sol";

/// @dev Sanity-check that mock Chainlink prices surface through CAP's oracle.
contract PriceOracleGetPriceTest is OracleFixture {
    function setUp() public {
        _setUpOracleFixture();
    }

    function test_price_oracle_get_price() public view {
        (uint256 usdtPrice,) = IOracle(env.infra.oracle).getPrice(address(usdt));
        assertEq(usdtPrice, 1e8, "USDT price should be $1");
    }
}
