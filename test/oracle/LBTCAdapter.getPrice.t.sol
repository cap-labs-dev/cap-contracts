// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";
import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { LBTCAdapter } from "../../contracts/oracle/libraries/LBTCAdapter.sol";
import { OracleFixture } from "../fixtures/OracleFixture.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockStakedLBTCOracle } from "../mocks/MockStakedLBTCOracle.sol";

/// @dev Verifies that LBTCAdapter correctly scales the Chainlink BTC/USD price by the
///      LBTC/BTC ratio returned by the staked LBTC oracle.
contract LBTCAdapterGetPriceTest is OracleFixture {
    MockERC20 lbtc;
    MockChainlinkPriceFeed btcFeed;
    MockStakedLBTCOracle lbtcOracle;

    int256 constant BTC_PRICE_8 = 96_000e8;
    uint256 constant LBTC_RATIO_18 = 1.001e18;

    function setUp() public {
        _setUpOracleFixture();

        lbtc = new MockERC20("Lombard BTC", "LBTC", 8);
        btcFeed = new MockChainlinkPriceFeed(BTC_PRICE_8);
        lbtcOracle = new MockStakedLBTCOracle(LBTC_RATIO_18);

        IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
            adapter: address(LBTCAdapter),
            payload: abi.encodeWithSelector(LBTCAdapter.price.selector, address(btcFeed), address(lbtcOracle))
        });

        vm.startPrank(env.users.oracle_admin);
        Oracle(env.infra.oracle).setPriceOracleData(address(lbtc), oracleData);
        Oracle(env.infra.oracle).setPriceBackupOracleData(address(lbtc), oracleData);
        vm.stopPrank();
    }

    function test_lbtc_price_scaled_by_ratio() public view {
        (uint256 price,) = IOracle(env.infra.oracle).getPrice(address(lbtc));
        uint256 expected = uint256(BTC_PRICE_8) * LBTC_RATIO_18 / 1 ether;
        assertEq(price, expected, "LBTC price must equal BTC price scaled by LBTC/BTC ratio");
    }

    function test_lbtc_ratio_one_equals_btc_price() public {
        lbtcOracle.setRate(1 ether);
        (uint256 price,) = IOracle(env.infra.oracle).getPrice(address(lbtc));
        assertEq(price, uint256(BTC_PRICE_8), "At 1:1 ratio LBTC price must equal BTC feed price");
    }

    function test_lbtc_btc_price_change_propagates() public {
        int256 newBtcPrice = 100_000e8;
        btcFeed.setLatestAnswer(newBtcPrice);
        (uint256 price,) = IOracle(env.infra.oracle).getPrice(address(lbtc));
        uint256 expected = uint256(newBtcPrice) * LBTC_RATIO_18 / 1 ether;
        assertEq(price, expected, "Price must track BTC feed updates");
    }

    function test_lbtc_ratio_change_propagates() public {
        uint256 newRatio = 1.01e18;
        lbtcOracle.setRate(newRatio);
        (uint256 price,) = IOracle(env.infra.oracle).getPrice(address(lbtc));
        uint256 expected = uint256(BTC_PRICE_8) * newRatio / 1 ether;
        assertEq(price, expected, "Price must track ratio oracle updates");
    }

    function test_lbtc_chainlink_feed_8_decimals_normalized() public view {
        // MockChainlinkPriceFeed defaults to 8 decimals — confirm no decimal mis-scaling.
        (uint256 price,) = IOracle(env.infra.oracle).getPrice(address(lbtc));
        assertGt(price, 0, "Price must be non-zero");
        // Sanity: price should be in the range of a realistic BTC/USD price (8 decimals, ~$96k)
        assertGt(price, 90_000e8, "Price must be above $90k (8 dec)");
        assertLt(price, 110_000e8, "Price must be below $110k (8 dec)");
    }
}
