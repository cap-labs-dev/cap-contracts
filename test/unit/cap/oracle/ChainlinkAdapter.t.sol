// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { MockAggregator, MockBareFeed } from "./MockChainlinkFeeds.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Direct tests for the adapter {Oracle} reads every price leg through.
///
/// Driven by staticcall throughout, because that is the only way {Oracle} ever reaches it and it
/// is worth knowing the payload and the return decode line up. A plain call would exercise a path
/// nothing uses. Composition is not tested here at all: the adapter answers one feed and {Oracle}
/// chains them, so that belongs in Oracle.t.sol.
contract ChainlinkAdapterTest is Test {
    ChainlinkAdapter internal adapter;

    function setUp() public {
        vm.warp(1_000_000);
        adapter = new ChainlinkAdapter();
    }

    function _read(address source) internal view returns (uint256 answer, uint256 updatedAt) {
        (bool ok, bytes memory ret) = address(adapter).staticcall(abi.encodeCall(ChainlinkAdapter.price, (source)));
        require(ok, "adapter reverted");
        (answer, updatedAt) = abi.decode(ret, (uint256, uint256));
    }

    function _expect(address source, bytes memory err) internal view {
        (bool ok, bytes memory ret) = address(adapter).staticcall(abi.encodeCall(ChainlinkAdapter.price, (source)));
        assertFalse(ok, "expected the adapter to refuse");
        assertEq(keccak256(ret), keccak256(err), "refused for the wrong reason");
    }

    // ── the ordinary path ─────────────────────────────────────────────────────

    /// @dev The payload {Oracle} stores is built with abi.encodeCall, which is the whole reason
    /// this is a contract and not a library. If it ever goes back to being a library this stops
    /// compiling, which is the intended alarm.
    function test_price_readsAnEightDecimalFeedThroughAStaticcall() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);

        (uint256 answer, uint256 updatedAt) = _read(address(feed));

        assertEq(answer, 2000e8, "passed through untouched at the adapter's own scale");
        assertEq(updatedAt, block.timestamp, "and stamped when the feed was");
    }

    function test_price_normalisesAnEighteenDecimalFeedDown() public {
        MockAggregator feed = new MockAggregator(18, 2000e18, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e8, "scaled to eight decimals");
    }

    function test_price_normalisesASixDecimalFeedUp() public {
        MockAggregator feed = new MockAggregator(6, 2000e6, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e8, "scaled to eight decimals");
    }

    // ── the circuit breaker ───────────────────────────────────────────────────

    /// @dev The finding worth having. An aggregator clamps to its bound instead of reporting
    /// through it, and keeps publishing the clamped figure on a fresh timestamp, so no staleness
    /// check anywhere upstream can see it. Collateral that has crashed goes on being valued at the
    /// floor, which keeps a market borrowing and out of reach of liquidation.
    function test_price_refusesAnAnswerRestingOnTheFloor() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        feed.setBounds(100e8, 10_000e8);

        // the real price collapses through the floor; the feed reports the floor, freshly stamped
        feed.setAnswer(100e8);

        _expect(
            address(feed),
            abi.encodeWithSelector(ChainlinkAdapter.AtCircuitBreaker.selector, address(feed), int256(100e8))
        );
    }

    function test_price_refusesAnAnswerRestingOnTheCeiling() public {
        MockAggregator feed = new MockAggregator(8, 10_000e8, block.timestamp);
        feed.setBounds(100e8, 10_000e8);

        _expect(
            address(feed),
            abi.encodeWithSelector(ChainlinkAdapter.AtCircuitBreaker.selector, address(feed), int256(10_000e8))
        );
    }

    function test_price_acceptsAnAnswerOneUnitInsideTheBounds() public {
        MockAggregator feed = new MockAggregator(8, 100e8 + 1, block.timestamp);
        feed.setBounds(100e8, 10_000e8);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 100e8 + 1, "inside is inside; only resting on the bound is a clamp");
    }

    /// @dev Fail-open, deliberately. Plenty of feeds answer neither hop, and refusing them would
    /// make serviceable feeds unusable while leaving them exactly where they were before the check
    /// existed.
    function test_price_acceptsAFeedThatPublishesNoBounds() public {
        MockBareFeed feed = new MockBareFeed(2000e8, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e8, "no bounds published means no bounds enforced");
    }

    // ── feeds that should be refused ──────────────────────────────────────────

    /// @dev Chainlink signals an unsettled round with a zero timestamp and documents its answer as
    /// not yet meaningful. Passing it on stamps a live price at the unix epoch, which only fails
    /// closed further up because the staleness check happens to measure against that stamp.
    function test_price_refusesAnUnsettledRound() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, 0);

        _expect(address(feed), abi.encodeWithSelector(ChainlinkAdapter.IncompleteRound.selector, address(feed)));
    }

    function test_price_refusesANegativeAnswer() public {
        MockAggregator feed = new MockAggregator(8, -1, block.timestamp);

        _expect(
            address(feed),
            abi.encodeWithSelector(ChainlinkAdapter.NonPositiveAnswer.selector, address(feed), int256(-1))
        );
    }

    /// @dev Named rather than folded into a zero, so a chain that composes to nothing says which
    /// leg did it.
    function test_price_refusesAZeroAnswer() public {
        MockAggregator feed = new MockAggregator(8, 0, block.timestamp);

        _expect(
            address(feed), abi.encodeWithSelector(ChainlinkAdapter.NonPositiveAnswer.selector, address(feed), int256(0))
        );
    }
}
