// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";

import { OracleFixture } from "../fixtures/OracleFixture.sol";

/// @dev Proves the adapter pricing path returns sane prices for CAP-issued vault tokens.
contract CapAdapterGetPriceTest is OracleFixture {
    function setUp() public {
        _setUpOracleFixture();
    }

    function test_cap_adapter_get_price() public view {
        (uint256 cUSDPrice,) = IOracle(env.infra.oracle).getPrice(address(cUSD));
        (uint256 scUSDPrice,) = IOracle(env.infra.oracle).getPrice(address(scUSD));
        assertApproxEqAbs(cUSDPrice, 1e8, 10, "cUSD price should be $1");
        assertApproxEqAbs(scUSDPrice, 1e8, 10, "scUSD price should be $1");
    }
}
