// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IChainlink
/// @author kexley, Cap Labs
/// @notice Chainlink reads used by {ChainlinkAdapter}.
///
/// Spans both hops of a feed. {decimals}, {latestRoundData} and {aggregator} are answered by the
/// proxy a feed address points at, while {minAnswer} and {maxAnswer} live on the aggregator behind
/// it. Kept in one interface because the adapter is the only caller and treats them as one feed.
interface IChainlink {
    /// @notice Decimals the aggregator reports its answer in
    /// @return decimals Answer decimals
    function decimals() external view returns (uint8 decimals);

    /// @notice Latest round recorded by the aggregator
    /// @return roundId Identifier of the round the answer came from
    /// @return answer Reported price, signed and capable of being negative
    /// @return startedAt When the round opened
    /// @return updatedAt When the answer was last written, zero while the round is unsettled
    /// @return answeredInRound Round the answer was actually computed in
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice The aggregator the proxy currently points at, which is where the bounds live
    /// @return aggregator Aggregator address
    function aggregator() external view returns (address aggregator);

    /// @notice Lower bound the aggregator will report. An answer resting on it is a clamp rather
    /// than a price
    /// @return minAnswer Lowest reportable answer
    function minAnswer() external view returns (int192 minAnswer);

    /// @notice Upper bound the aggregator will report. An answer resting on it is a clamp rather
    /// than a price
    /// @return maxAnswer Highest reportable answer
    function maxAnswer() external view returns (int192 maxAnswer);
}
