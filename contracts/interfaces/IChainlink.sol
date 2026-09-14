// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IChainlink
/// @author kexley, Cap Labs
/// @notice Interface for the Chainlink reads used by {ChainlinkAdapter}
interface IChainlink {
    /// @notice Get the decimals the aggregator reports its answer in
    /// @return decimals The answer decimals
    function decimals() external view returns (uint8 decimals);

    /// @notice Get the latest round recorded by the aggregator
    /// @return roundId The identifier of the round the answer came from
    /// @return answer The reported price, signed and capable of being negative
    /// @return startedAt When the round opened
    /// @return updatedAt When the answer was last written, zero while the round is unsettled
    /// @return answeredInRound The round the answer was actually computed in
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
