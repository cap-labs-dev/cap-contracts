// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// L-15 (round 2): the Chainlink min/max-answer circuit breaker was DELETED. Round 1 showed it
// failed open when `aggregator()` was missing; now an answer pinned to the feed's published
// floor (LUNA-style) is served as a live price and the secondary is never consulted.
import { ChainlinkAdapter } from "../../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IOracle } from "../../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../../../test/shared/mocks/MockChainlinkFeeds.sol";

/// @dev A feed that publishes its own min/max bounds and points `aggregator()` at itself, i.e. the
/// shape a circuit-breaker check would have every reason to accept
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

    function setBounds(int192 _min, int192 _max) external {
        minAnswer = _min;
        maxAnswer = _max;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract L15_CircuitBreaker is CapDeployer {
    address internal asset = makeAddr("luna");
    BoundedAggregator internal primaryFeed;
    MockAggregator internal secondaryFeed;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        // primary: healthy at $100, floor $1, cap $10,000
        primaryFeed = new BoundedAggregator(100e8, 1e8, 10_000e8);
        // secondary: an independent feed that knows the real (collapsed) price, $0.0001
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

    /// @dev NEW PoC: answer == minAnswer must not be a live price
    function test_L15_answerOnFloorServedAsLivePrice() public {
        // the market collapses; the aggregator clamps at its floor
        primaryFeed.setAnswer(int256(int192(primaryFeed.minAnswer())));
        secondaryFeed.setUpdatedAt(block.timestamp);

        uint256 observed = oracle.price(asset);
        emit log_named_decimal_uint("minAnswer (18 dec)", uint256(uint192(primaryFeed.minAnswer())) * 1e10, 18);
        emit log_named_decimal_uint("Oracle.price(asset) observed", observed, 18);
        emit log_named_decimal_uint("secondary (true) price", 0.0001e18, 18);

        assertNotEq(observed, 1e18, "an answer resting on the published floor must be refused");
        assertEq(observed, 0.0001e18, "the oracle should fall back to the secondary");
    }

    /// @dev Ported round-1 test_H4a: adapter-level read of a floor-clamped answer
    function test_H4a_floorAcceptedWhenAggregatorHopMissing() public {
        BoundedAggregator feed = new BoundedAggregator(100e8, 100e8, 10_000e8);
        (bool ok, bytes memory ret) =
            chainlinkAdapter.staticcall(abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)));
        uint256 answer;
        if (ok) {
            (answer,) = abi.decode(ret, (uint256, uint256));
            emit log_named_uint("adapter accepted clamped answer", answer);
        }
        // identical meaning to round 1: a floor-clamped answer must not come back as a valid price
        assertTrue(!ok || answer == 0, "an answer resting on the published floor must be refused");
    }
}
