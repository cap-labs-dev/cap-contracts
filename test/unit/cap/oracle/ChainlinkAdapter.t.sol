// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { MockAggregator } from "../../../shared/mocks/MockChainlinkFeeds.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Direct tests for the adapter {Oracle} reads every price leg through.
///
/// Driven by staticcall throughout, because that is the only way {Oracle} ever reaches it and it
/// is worth knowing the payload and the return decode line up. A plain call would exercise a path
/// nothing uses. Composition is not tested here at all: the adapter answers one feed and {Oracle}
/// chains them, so that belongs in Oracle.t.sol.
contract ChainlinkAdapterTest is Test {
    address internal adapter;

    function setUp() public {
        vm.warp(1_000_000);
        bytes memory adapterCode = type(ChainlinkAdapter).creationCode;
        address deployed;
        assembly {
            deployed := create(0, add(adapterCode, 0x20), mload(adapterCode))
        }
        adapter = deployed;
    }

    function _read(address source) internal view returns (uint256 answer, uint256 updatedAt) {
        (bool ok, bytes memory ret) =
            adapter.staticcall(abi.encodeWithSelector(ChainlinkAdapter.price.selector, source));
        require(ok, "adapter reverted");
        (answer, updatedAt) = abi.decode(ret, (uint256, uint256));
    }

    function _expectZero(address source) internal view {
        (uint256 answer,) = _read(source);
        assertEq(answer, 0, "unusable feed is a zero, not a revert");
    }

    // ── the ordinary path ─────────────────────────────────────────────────────

    function test_price_normalisesAnEightDecimalFeedUp() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);

        (uint256 answer, uint256 updatedAt) = _read(address(feed));

        assertEq(answer, 2000e18, "eight is what a real USD feed reports, and it scales up to meet the oracle");
        assertEq(updatedAt, block.timestamp, "and stamped when the feed was");
    }

    /// @dev Nothing to do, and the case worth naming: the adapter's scale is the oracle's, so a
    /// feed already reporting eighteen is passed through. Pins the constant from the outside,
    /// since it is private, and a drift back down to a feed's native eight would land here.
    function test_price_readsAnEighteenDecimalFeedUntouched() public {
        MockAggregator feed = new MockAggregator(18, 2000e18, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e18, "already in the oracle's scale");
    }

    function test_price_normalisesASixDecimalFeedUp() public {
        MockAggregator feed = new MockAggregator(6, 2000e6, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e18, "scaled to eighteen decimals");
    }

    /// @dev No USD feed reports above eighteen, but the branch exists and truncates, so it is
    /// held to the direction it truncates in rather than left to be discovered.
    function test_price_normalisesAFeedAboveTheScaleDown() public {
        MockAggregator feed = new MockAggregator(21, 2000e21 + 999, block.timestamp);

        (uint256 answer,) = _read(address(feed));

        assertEq(answer, 2000e18, "scaled down, and the sub-wei remainder dropped rather than rounded up");
    }

    // ── feeds that should be refused ──────────────────────────────────────────

    /// @dev An unsettled round is stamped at zero. The adapter still answers; staleness is the
    /// oracle's to measure.
    function test_price_passesThroughAnUnsettledRound() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, 0);

        (uint256 answer, uint256 updatedAt) = _read(address(feed));

        assertEq(answer, 2000e18);
        assertEq(updatedAt, 0);
    }

    function test_price_refusesANegativeAnswer() public {
        MockAggregator feed = new MockAggregator(8, -1, block.timestamp);

        _expectZero(address(feed));
    }

    function test_price_refusesAZeroAnswer() public {
        MockAggregator feed = new MockAggregator(8, 0, block.timestamp);

        _expectZero(address(feed));
    }
}
