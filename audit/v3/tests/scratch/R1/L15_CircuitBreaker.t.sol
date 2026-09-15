// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// Round-3 port of round-1 L-15 / round-2 R2-L2. `ChainlinkAdapter.price` (:20-32) only rejects
/// `answer <= 0`; HEAD NatSpec (:9-10) now documents the missing clamp check as deliberate and
/// pushes it to "feed onboarding". A feed pinned to its published floor is served as live.
contract BoundedAggregator {
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

    function aggregator() external view returns (address) {
        return address(this);
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract R1_L15_CircuitBreaker is CapDeployer {
    address internal asset = makeAddr("luna");
    BoundedAggregator internal primaryFeed;
    MockAggregator internal secondaryFeed;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        primaryFeed = new BoundedAggregator(100e8, 1e8, 10_000e8);
        secondaryFeed = new MockAggregator(8, 0.0001e8, block.timestamp);

        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(primaryFeed)),
            staleness: 1 hours
        });
        hops[0].secondary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(secondaryFeed)),
            staleness: 1 hours
        });
        oracle.setSource(asset, hops);
        assertEq(oracle.price(asset), 100e18, "healthy primary served");
    }

    function test_L15_answerOnFloorServedAsLivePrice() public {
        primaryFeed.setAnswer(int256(int192(primaryFeed.minAnswer())));
        secondaryFeed.setUpdatedAt(block.timestamp);
        uint256 observed = oracle.price(asset);
        emit log_named_decimal_uint("minAnswer (18 dec)", uint256(uint192(primaryFeed.minAnswer())) * 1e10, 18);
        emit log_named_decimal_uint("Oracle.price(asset) observed", observed, 18);
        emit log_named_decimal_uint("secondary (true) price", 0.0001e18, 18);
        assertNotEq(observed, 1e18, "an answer resting on the published floor must be refused");
        assertEq(observed, 0.0001e18, "the oracle should fall back to the secondary");
    }

    function test_H4a_floorAcceptedAtAdapter() public {
        BoundedAggregator feed = new BoundedAggregator(100e8, 100e8, 10_000e8);
        (bool ok, bytes memory ret) =
            chainlinkAdapter.staticcall(abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)));
        uint256 answer;
        if (ok) (answer,) = abi.decode(ret, (uint256, uint256));
        emit log_named_uint("adapter answer for a floor-clamped feed", answer);
        assertTrue(!ok || answer == 0, "an answer resting on the published floor must be refused");
    }
}
