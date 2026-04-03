// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { OracleFixture } from "../fixtures/OracleFixture.sol";

/// @dev Sanity-check that mock Aave rates surface through CAP's oracle in ray decimals.
contract RateOracleGetRateTest is OracleFixture {
    function setUp() public {
        _setUpOracleFixture();
    }

    function test_rate_oracle_get_rate() public {
        uint256 usdtRate = IOracle(env.infra.oracle).marketRate(address(usdt));
        assertEq(usdtRate, 1e26, "USDT borrow rate should be 10%, 1e27 being 100%");
    }
}
