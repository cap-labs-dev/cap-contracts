// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// Round-3 port of round-1 L-16 (E3). `Oracle._isStale` (:95-101) only fires when
/// `now > lastUpdated`; a future-dated stamp is fresh forever and the secondary is never consulted.
contract R1_L16_FutureStamp is CapDeployer {
    address internal asset = makeAddr("asset");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
    }

    function test_H4b_futureDatedAnswerIsNeverStale() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp + 3650 days);
        MockAggregator secondary = new MockAggregator(8, 1500e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 1 hours
        });
        hops[0].secondary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(secondary)),
            staleness: 3650 days
        });
        oracle.setSource(asset, hops);

        skip(5 * 365 days);
        uint256 answer = oracle.price(asset);
        emit log_named_decimal_uint("price served after 5 years of primary silence", answer, 18);
        emit log_named_uint("primary stamp", feed.updatedAt());
        emit log_named_uint("now", block.timestamp);
        assertNotEq(answer, 2000e18, "a 1-hour window must not serve a five-year-old configuration");
        assertEq(answer, 1500e18, "the secondary should have been consulted");
    }

    function test_H4b_control_pastStampGoesStale() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 1 hours
        });
        oracle.setSource(asset, hops);
        skip(1 hours + 1);
        assertEq(oracle.price(asset), 0, "past-stamped feed correctly goes stale");
    }
}
