// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";
import { IRateOracle } from "../../contracts/interfaces/IRateOracle.sol";
import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { MarketRateAdapter } from "../../contracts/oracle/libraries/MarketRateAdapter.sol";
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

    /// @dev Setting adapter=address(0) with empty payload does NOT return 0 gracefully.
    ///      address(0).call("") succeeds (no code) but returns empty data, causing
    ///      abi.decode to revert rather than returning the default 0.
    function test_market_rate_zero_adapter_reverts() public {
        vm.prank(env.users.rate_oracle_admin);
        Oracle(env.infra.oracle)
            .setMarketOracleData(address(usdt), IOracleTypes.OracleData({ adapter: address(0), payload: bytes("") }));

        vm.expectRevert();
        IOracle(env.infra.oracle).marketRate(address(usdt));
    }

    /// @dev MarketRateAdapter.rate() always returns 0, so marketRate returns 0
    ///      and the interest rate calculation falls back to benchmarkRate as the floor.
    function test_market_rate_adapter_returns_zero() public {
        uint256 marketRateBefore = IOracle(env.infra.oracle).marketRate(address(usdt));
        assertGt(marketRateBefore, 0, "market rate must be non-zero before swap");

        vm.prank(env.users.rate_oracle_admin);
        Oracle(env.infra.oracle)
            .setMarketOracleData(
                address(usdt),
                IOracleTypes.OracleData({
                adapter: address(MarketRateAdapter), payload: abi.encodeWithSelector(MarketRateAdapter.rate.selector)
            })
            );

        uint256 marketRateAfter = IOracle(env.infra.oracle).marketRate(address(usdt));
        assertEq(marketRateAfter, 0, "MarketRateAdapter must return 0");
        assertLt(marketRateAfter, marketRateBefore, "market rate must decrease after swap");

        // Total borrow rate = max(marketRate, benchmarkRate) + utilizationRate.
        // With marketRate=0, benchmarkRate becomes the floor — verify it is still non-zero.
        uint256 benchmarkRate = IOracle(env.infra.oracle).benchmarkRate(address(usdt));
        assertGt(benchmarkRate, 0, "benchmarkRate must be non-zero so total borrow rate stays positive");
    }
}
