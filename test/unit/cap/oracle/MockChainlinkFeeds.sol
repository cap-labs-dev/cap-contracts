// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice A feed exposing the aggregator hop, so the circuit-breaker bounds are reachable.
///
/// Points {aggregator} at itself, which is enough to exercise both hops without a second contract.
/// Bounds default to the full int192 range, which is how a feed that publishes them but does not
/// constrain anything behaves.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    int192 public minAnswer;
    int192 public maxAnswer;

    constructor(uint8 _decimals, int256 _answer, uint256 _updatedAt) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = _updatedAt;
        minAnswer = type(int192).min;
        maxAnswer = type(int192).max;
    }

    function setBounds(int192 _min, int192 _max) external {
        minAnswer = _min;
        maxAnswer = _max;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice A feed answering no bounds at all, as plenty of real ones do
contract MockBareFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice An adapter-shaped stub returning whatever a test wants, for exercising {Oracle} without
/// dragging a Chainlink feed in behind every leg
contract MockAdapter {
    uint256 public answer;
    uint256 public updatedAt;
    bool public reverts;
    bool public returnsShort;

    constructor(uint256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function set(uint256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function setReverts(bool _reverts) external {
        reverts = _reverts;
    }

    /// @dev A rate-style adapter that answers a value with no timestamp returns one word, which is
    /// the shape {Oracle-_read} has to refuse rather than decode
    function setReturnsShort(bool _short) external {
        returnsShort = _short;
    }

    function price() external view returns (uint256, uint256) {
        require(!reverts, "adapter down");
        return (answer, updatedAt);
    }

    function shortPrice() external view returns (uint256) {
        return answer;
    }
}
