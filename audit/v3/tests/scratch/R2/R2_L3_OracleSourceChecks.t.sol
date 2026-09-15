// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IChainlink } from "../../../../../contracts/interfaces/IChainlink.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// Round-3 re-check of round-2 R2-L3. HEAD `Oracle._read` (:80-92) requires exactly 64 return
/// bytes (142ec65), so a raw feed as payload (5 words) is refused. `setSource`'s dry run (:36)
/// still only checks `!= 0`: the same feed listed twice prices at p^2/1e18.
contract R2_L3_OracleSourceChecks is CapDeployer {
    address internal asset = makeAddr("asset");
    MockAggregator feed;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        feed = new MockAggregator(8, 2000e8, block.timestamp);
    }

    function test_rawFeedAsPayloadIsRefused() public {
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: address(feed),
            payload: abi.encodeWithSelector(IChainlink.latestRoundData.selector),
            staleness: 1 hours
        });
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, asset));
        oracle.setSource(asset, hops);
    }

    function test_feedListedTwicePricesSquared() public {
        IOracle.Sources[] memory hops = new IOracle.Sources[](2);
        for (uint256 i; i < 2; ++i) {
            hops[i].primary = IOracle.Source({
                adapter: chainlinkAdapter,
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
                staleness: 1 hours
            });
        }
        (bool ok,) = address(oracle).call(abi.encodeCall(oracle.setSource, (asset, hops)));
        emit log_named_string("setSource with the same feed twice", ok ? "accepted" : "rejected");
        if (ok) emit log_named_decimal_uint("Oracle.price", oracle.price(asset), 18);
        assertFalse(ok, "a chain that repeats a feed must be rejected by the dry run");
    }
}
