// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAdapter, MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// @dev a feed whose decimals() reverts, and one that answers > 18 decimals
contract RevertingDecimalsFeed {
    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice N8 — oracle regressions on 3dad5ef, plus L-16 port.
contract N4_Oracle is CapDeployer {
    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
    }

    function _hop(address adapter, bytes memory payload, uint256 staleness)
        internal
        pure
        returns (IOracle.Sources memory s)
    {
        s.primary = IOracle.Source({ adapter: adapter, payload: payload, staleness: staleness });
    }

    function _clPayload(address feed) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ChainlinkAdapter.price.selector, feed);
    }

    // ── N8(a): minAnswer clamp accepted with no defence ──────────────────────
    /// A LUNA-style collapse: the aggregator clamps at minAnswer = 0.1 USD while the true price is
    /// 0.0001 USD. The oracle accepts the clamped, freshly-stamped answer; the borrower borrows against
    /// 1000x overvalued tranche collateral; the debt is unrecoverable at the true price.
    function test_N8a_minAnswerClampIsAcceptedAndCreatesUnrecoverableDebt() public {
        // "LUNA" collateral, 18 dec, feed stamps fresh at the clamp price 0.1e8
        uint256 clamp = 0.1e18;
        uint256 truePrice = 0.0001e18;
        (address marketAddr, address senior, address junior) = _createMarket("luna");
        FloatingMarket market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(1_000_000e18);
        _setPrice(address(collateral), clamp);
        _fundTranche(senior, makeAddr("s"), 1_000_000e18); // 1M LUNA @ 0.1 = $100k "value"
        _fundTranche(junior, makeAddr("j"), 1_000_000e18);
        // borrow up to LTV against the clamped valuation
        uint256 cap = market.totalCapital();
        assertEq(cap, 200_000e18, "oracle values 2M LUNA at the clamp: $200k");
        uint256 principal = cap * market.ltv() / 1e27 - 1e18;
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, principal);
        assertGe(market.healthiness(), 1e27, "healthy at the clamped price");
        assertEq(market.unrecoverableDebt(), 0, "nothing recognisable while clamped");

        // what the market is really worth: only visible if the feed were honest
        _setPrice(address(collateral), truePrice);
        assertEq(market.totalCapital(), 200e18, "true value of the collateral: $200");
        assertGt(market.unrecoverableDebt(), principal - 300e18, "essentially the whole loan is bad debt");
        // Oracle has nothing to say about it: no bounds, no revert, price stays > 0 and fresh
        _setPrice(address(collateral), clamp);
        assertEq(oracle.price(address(collateral)), clamp);
        emit log_named_uint("cUSD minted against a $200 asset base", principal);
    }

    // ── N8(b): unconfigured asset → 0 ─────────────────────────────────────────
    function test_N8b_unconfiguredAssetReturnsZeroAndTrancheReverts() public {
        address unpriced = address(new MockAggregator(8, 1, 1)); // any address
        assertEq(oracle.price(unpriced), 0);
        // an asset whose chain was deleted after tranche creation: totalCapital reverts (M-1 open)
        (address marketAddr,,) = _createMarket("m");
        IOracle.Sources[] memory none;
        oracle.setSource(address(collateral), none); // empty chain passes the dry-run
        assertEq(oracle.price(address(collateral)), 0);
        vm.expectRevert();
        FloatingMarket(marketAddr).totalCapital();
    }

    // ── N8(c): raw feed as payload → roundId is the price, startedAt the stamp ─
    function test_N8c_rawFeedPayloadServesRoundIdAsPrice() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        // misconfiguration: the feed itself as adapter, latestRoundData as payload
        hops[0] = _hop(address(feed), abi.encodeWithSelector(feed.latestRoundData.selector), 1 hours);
        oracle.setSource(address(collateral), hops); // dry-run passes: roundId = 1 != 0
        assertEq(oracle.price(address(collateral)), 1, "roundId (1) is served as the 18-dec price");
        // and with startedAt as 'lastUpdated' it is stale only if startedAt is old; a feed whose
        // roundId encodes phase (e.g. 18446744073709551617) would be served as a huge price
    }

    // ── N8(d): scale paths ────────────────────────────────────────────────────
    function test_N8d_scaleAndDecimalsFailurePaths() public {
        // 18-dec feed: no scaling
        MockAggregator f18 = new MockAggregator(18, 2000e18, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(f18)), 1 hours);
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 2000e18);
        // 27-dec feed: divided down, truncating
        MockAggregator f27 = new MockAggregator(27, 2000e27 + 999_999_999, block.timestamp);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(f27)), 1 hours);
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 2000e18);
        // decimals() reverts → adapter reverts → _read returns 0 → secondary
        RevertingDecimalsFeed bad = new RevertingDecimalsFeed();
        MockAdapter secondary = new MockAdapter(1999e18, block.timestamp);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(bad)), 1 hours);
        hops[0].secondary = IOracle.Source({
            adapter: address(secondary), payload: abi.encodeWithSelector(MockAdapter.price.selector), staleness: 1 hours
        });
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 1999e18, "fell through to secondary");
        // negative / zero answer → (0, stamp) → secondary
        MockAggregator neg = new MockAggregator(8, -1, block.timestamp);
        hops[0].primary =
            IOracle.Source({ adapter: chainlinkAdapter, payload: _clPayload(address(neg)), staleness: 1 hours });
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 1999e18);
        // no secondary and primary fails → 0 (Tranche reverts)
        hops[0].secondary = IOracle.Source({ adapter: address(0), payload: "", staleness: 0 });
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, address(collateral)));
        oracle.setSource(address(collateral), hops);
    }

    // ── N8(e): dry-run accepts any non-zero price ─────────────────────────────
    function test_N8e_dryRunAcceptsScaleErrors() public {
        // the same feed twice as a 2-hop chain: price^2 / 1e18 → 2000*2000 = 4e6 e18: off by 2000x
        MockAggregator f = new MockAggregator(8, 2000e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](2);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(f)), 1 hours);
        hops[1] = hops[0];
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 4_000_000e18);
        // a raw 36-dec adapter passes as well
        MockAdapter a36 = new MockAdapter(2000e36, block.timestamp);
        hops = new IOracle.Sources[](1);
        hops[0] = _hop(address(a36), abi.encodeWithSelector(MockAdapter.price.selector), 1 hours);
        oracle.setSource(address(collateral), hops);
        assertEq(oracle.price(address(collateral)), 2000e36);
    }

    // ── N8(f): 3-hop composition precision ────────────────────────────────────
    /// hop prices p1,p2,p3 in 18 dec: result = floor(floor(p1*p2/1e18)*p3/1e18). Error ≤ p3/1e18 + 1 wei.
    function testFuzz_N8f_threeHopChainError(uint64 p1, uint64 p2, uint64 p3) public {
        vm.assume(p1 > 0 && p2 > 0 && p3 > 0);
        MockAdapter a1 = new MockAdapter(p1, block.timestamp);
        MockAdapter a2 = new MockAdapter(p2, block.timestamp);
        MockAdapter a3 = new MockAdapter(p3, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](3);
        hops[0] = _hop(address(a1), abi.encodeWithSelector(MockAdapter.price.selector), 1 hours);
        hops[1] = _hop(address(a2), abi.encodeWithSelector(MockAdapter.price.selector), 1 hours);
        hops[2] = _hop(address(a3), abi.encodeWithSelector(MockAdapter.price.selector), 1 hours);
        uint256 got = oracle.price(hops);
        // exact: p1*p2*p3 / 1e36, fits in 256 bits for uint64 inputs
        uint256 exact = uint256(p1) * uint256(p2) * uint256(p3) / 1e36;
        assertLe(exact - got, uint256(p3) / 1e18 + 1, "composition error bounded by p3/1e18 + 1 wei");
        assertGe(exact, got, "always floors");
    }

    // ── L-16: future-dated stamp is never stale ──────────────────────────────
    function test_L16_futureStampNeverStale() public {
        MockAggregator f = new MockAggregator(8, 2000e8, block.timestamp + 365 days);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(f)), 1 hours);
        oracle.setSource(address(collateral), hops);
        vm.warp(block.timestamp + 364 days); // 364 days without an update, staleness = 1h
        assertEq(oracle.price(address(collateral)), 2000e18, "still 'fresh': L-16 open");
        vm.warp(block.timestamp + 2 days);
        assertEq(oracle.price(address(collateral)), 0, "only stale once the stamp is 1h in the past");
    }

    // zero stamp (IncompleteRound replacement) → staleness → 0
    function test_N8_zeroStampIsStale() public {
        MockAggregator f = new MockAggregator(8, 2000e8, 0);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0] = _hop(chainlinkAdapter, _clPayload(address(f)), 1 hours);
        vm.expectRevert();
        oracle.setSource(address(collateral), hops);
    }
}
