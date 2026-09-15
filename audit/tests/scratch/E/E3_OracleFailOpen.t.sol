// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { MockAggregator } from "../../../../test/unit/cap/oracle/MockChainlinkFeeds.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

/// @notice A feed configured at the aggregator itself rather than at its proxy: it publishes
/// bounds but has no `aggregator()` hop, which is how every Chainlink aggregator looks when
/// addressed directly
contract MockDirectAggregator {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    int192 public minAnswer;
    int192 public maxAnswer;

    constructor(int256 _answer, int192 _min, int192 _max) {
        answer = _answer;
        updatedAt = block.timestamp;
        minAnswer = _min;
        maxAnswer = _max;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice E-3 / E-4 (H4): the circuit breaker fails open on a missing hop and the staleness
/// check treats a future-dated answer as fresh forever.
contract E3_OracleFailOpen is Test {
    ChainlinkAdapter internal adapter;
    Oracle internal oracle;
    AccessManager internal am;
    address internal asset = makeAddr("asset");

    function setUp() public {
        vm.warp(1_000_000);
        adapter = new ChainlinkAdapter();
        am = new AccessManager(address(this));
        oracle =
            Oracle(address(new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(am))))));
        bytes4[] memory s = new bytes4[](2);
        s[0] = Oracle.setSource.selector;
        s[1] = Oracle.setBackup.selector;
        am.setTargetFunctionRole(address(oracle), s, am.ADMIN_ROLE());
    }

    function _adapterRead(address feed) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(adapter).staticcall(abi.encodeCall(ChainlinkAdapter.price, (feed)));
    }

    /// @dev H4(a): an answer resting exactly on minAnswer is a clamp, not a price. The adapter
    /// has the bounds one call away on `_source` itself but never looks because `aggregator()`
    /// reverted. LUNA-style: collateral at $0.001 is valued at the $100 floor.
    function test_H4a_floorAcceptedWhenAggregatorHopMissing() public {
        MockDirectAggregator feed = new MockDirectAggregator(100e8, 100e8, 10_000e8);
        (bool ok, bytes memory ret) = _adapterRead(address(feed));
        if (ok) {
            (uint256 answer,) = abi.decode(ret, (uint256, uint256));
            emit log_named_uint("adapter accepted clamped answer", answer);
        }
        assertFalse(ok, "an answer resting on the published floor must be refused");
    }

    /// @dev H4(b): `_isStale` returns false whenever lastUpdated > now. A feed that once wrote a
    /// future timestamp is fresh for the life of the configuration.
    function test_H4b_futureDatedAnswerIsNeverStale() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp + 3650 days);
        oracle.setSource(
            asset,
            IOracle.OracleData({
                adapter: address(adapter),
                payload: abi.encodeCall(ChainlinkAdapter.price, (address(feed))),
                staleness: 1 hours
            })
        );
        skip(5 * 365 days); // nothing has written for five years
        (bool ok, bytes memory ret) = address(oracle).staticcall(abi.encodeCall(IOracle.price, (asset)));
        if (ok) {
            (uint256 answer, uint256 at) = abi.decode(ret, (uint256, uint256));
            emit log_named_uint("price still served after 5 years of silence", answer);
            emit log_named_uint("its stamp", at);
            emit log_named_uint("now", block.timestamp);
        }
        assertFalse(ok, "a 1-hour window must not serve a five-year-old configuration");
    }

    /// @dev Compounding misconfiguration: `Oracle._read` decodes `(uint256,uint256)` from any
    /// return of >= 64 bytes. Pointing an entry at the feed's own `latestRoundData()` (adapter =
    /// feed, no ChainlinkAdapter in between) reads (roundId, answer) as (price, timestamp): the
    /// price becomes the round id and the timestamp becomes the answer, which is in the future,
    /// so the entry is never stale either.
    function test_H4c_rawFeedEntryDecodesRoundIdAsPriceAndIsNeverStale() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        oracle.setSource(
            asset,
            IOracle.OracleData({
                adapter: address(feed), payload: abi.encodeCall(MockAggregator.latestRoundData, ()), staleness: 1 hours
            })
        );
        skip(365 days);
        (bool ok, bytes memory ret) = address(oracle).staticcall(abi.encodeCall(IOracle.price, (asset)));
        if (ok) {
            (uint256 answer, uint256 at) = abi.decode(ret, (uint256, uint256));
            emit log_named_uint("price served (= roundId)", answer);
            emit log_named_uint("stamp served (= answer 2000e8, i.e. year 8306)", at);
        }
        assertFalse(ok, "a raw-feed entry must not decode into a live price");
    }
}
