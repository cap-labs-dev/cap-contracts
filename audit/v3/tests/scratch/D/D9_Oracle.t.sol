// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAdapter, MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// WS-D item 8: oracle edge behaviour.
contract D9_Oracle is CapDeployer {
    address asset = makeAddr("asset");

    function setUp() public {
        _deployCap();
    }

    function _hop(address adapter, bytes memory payload, uint256 staleness)
        internal
        pure
        returns (IOracle.Sources memory s)
    {
        s.primary = IOracle.Source({ adapter: adapter, payload: payload, staleness: staleness });
    }

    /// A future-stamped answer is never stale, for any staleness window.
    function test_futureStampNeverStale() public {
        MockAdapter a = new MockAdapter(1e18, block.timestamp + 365 days);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(address(a), abi.encodeWithSelector(MockAdapter.price.selector), 1);
        oracle.setSource(asset, hops);
        skip(300 days);
        assertEq(oracle.price(asset), 1e18, "still fresh 300 days later");
    }

    /// Chain product floors once per hop: 3 hops lose at most ~2 wei of 1e18.
    function test_threeHopPrecision() public {
        uint256 p1 = 999_999_999_999_999_999; // 1 - 1e-18
        uint256 p2 = 1_234_567_891_234_567_891;
        uint256 p3 = 3_333_333_333_333_333_333;
        IOracle.Sources[] memory hops = new IOracle.Sources[](3);
        hops[0] = _hop(
            address(new MockAdapter(p1, block.timestamp)), abi.encodeWithSelector(MockAdapter.price.selector), 1 days
        );
        hops[1] = _hop(
            address(new MockAdapter(p2, block.timestamp)), abi.encodeWithSelector(MockAdapter.price.selector), 1 days
        );
        hops[2] = _hop(
            address(new MockAdapter(p3, block.timestamp)), abi.encodeWithSelector(MockAdapter.price.selector), 1 days
        );
        oracle.setSource(asset, hops);
        uint256 got = oracle.price(asset);
        uint256 exact = p1 * p2 * p3 / 1e36; // floor of the exact product
        assertLe(exact - got, 2, "at most one wei per extra hop");
        emit log_named_uint("exact", exact);
        emit log_named_uint("got  ", got);
    }

    /// decimals > 18 floors; decimals < 18 scales up exactly.
    function test_adapterDecimalsAboveEighteen() public {
        MockAggregator f20 = new MockAggregator(20, int256(1e20 + 99), block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(chainlinkAdapter, abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(f20)), 1 days);
        oracle.setSource(asset, hops);
        assertEq(oracle.price(asset), 1e18);
    }

    /// setSource's dry-run only rejects zero: a wrong-scale source (answer already in 8 dec via a
    /// pass-through adapter) is accepted and prices the asset at 1e-10 USD.
    function test_setSourceAcceptsWrongScale() public {
        MockAdapter a = new MockAdapter(1e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(address(a), abi.encodeWithSelector(MockAdapter.price.selector), 1 days);
        oracle.setSource(asset, hops); // accepted
        assertEq(oracle.price(asset), 1e8);
        // and an absurdly high one too
        a.set(1e40, block.timestamp);
        oracle.setSource(asset, hops);
        assertEq(oracle.price(asset), 1e40);
    }

    /// Staleness 0 accepts only an answer stamped in this very block; a feed heartbeat longer than
    /// the configured window makes the asset periodically unpriced.
    function test_stalenessWindowVsHeartbeat() public {
        MockAggregator f = new MockAggregator(8, 1e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(chainlinkAdapter, abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(f)), 1 hours);
        oracle.setSource(asset, hops);
        assertEq(oracle.price(asset), 1e18);
        skip(1 hours);
        assertEq(oracle.price(asset), 1e18, "exactly at the bound is fresh");
        skip(1);
        assertEq(oracle.price(asset), 0, "one second past is zero");
    }

    /// Empty chain and cleared chain both answer zero; the dry-run lets an empty chain through.
    function test_emptyChainIsZero() public {
        assertEq(oracle.price(asset), 0);
        oracle.setSource(address(collateral), new IOracle.Sources[](0));
        assertEq(oracle.price(address(collateral)), 0);
    }
}
