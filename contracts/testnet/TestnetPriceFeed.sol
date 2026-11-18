// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestnetPriceFeed
/// @notice A Chainlink-shaped price feed whose answer the owner sets, for testnet collateral that
/// has no real feed and for scripted price moves (liquidation rehearsals).
/// @dev Read through {ChainlinkAdapter}. `updatedAt` is `block.timestamp` unless the owner freezes
/// it, so the oracle never sees this feed as stale between manual updates. Not for production.
contract TestnetPriceFeed is Ownable {
    /// @notice Answer decimals, fixed to what a real Chainlink USD feed reports
    uint8 public constant decimals = 8;

    /// @notice Feed description, e.g. "stETH / USD"
    string public description;

    /// @notice The current answer in `decimals`
    int256 public answer;

    /// @notice Frozen `updatedAt`; zero means "now"
    uint256 public frozenUpdatedAt;

    /// @notice Incremented on every answer change
    uint80 public roundId;

    /// @notice Emitted when the owner changes the answer
    /// @param answer The new answer
    /// @param roundId The new round id
    event AnswerUpdated(int256 answer, uint80 roundId);

    /// @param admin The only account allowed to move the price; also the owner
    /// @param description_ Human-readable feed description
    /// @param initialAnswer The starting answer in `decimals`
    constructor(address admin, string memory description_, int256 initialAnswer) Ownable(admin) {
        description = description_;
        answer = initialAnswer;
        roundId = 1;
    }

    /// @notice Set a new answer. Owner only.
    /// @param newAnswer The answer in `decimals`
    function setAnswer(int256 newAnswer) external onlyOwner {
        answer = newAnswer;
        ++roundId;
        emit AnswerUpdated(newAnswer, roundId);
    }

    /// @notice Freeze `updatedAt` at a timestamp (to rehearse staleness), or zero to report "now"
    /// @param timestamp The timestamp to report, or zero
    function setFrozenUpdatedAt(uint256 timestamp) external onlyOwner {
        frozenUpdatedAt = timestamp;
    }

    /// @notice Chainlink `latestRoundData`
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 updatedAt = frozenUpdatedAt == 0 ? block.timestamp : frozenUpdatedAt;
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    /// @notice Chainlink `latestAnswer`
    function latestAnswer() external view returns (int256) {
        return answer;
    }
}
