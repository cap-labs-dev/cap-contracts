// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IChainlink } from "../../interfaces/IChainlink.sol";

/// @title Chainlink Adapter Chained
/// @author kexley, Cap Labs
/// @notice Prices are sourced from Chainlink
library ChainlinkAdapterChained {
    /// @notice Fetch price for an asset from Chainlink fixed to 8 decimals from a chain of sources
    /// @param _sources Chainlink aggregators
    /// @return latestAnswer Price of the asset fixed to 8 decimals
    /// @return lastUpdated Last updated timestamp
    function price(address[] memory _sources) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        (latestAnswer, lastUpdated) = _getPrice(_sources[0]);

        uint256 sourcesLength = _sources.length;
        for (uint256 i = 1; i < sourcesLength; ++i) {
            (uint256 intermediateAnswer, uint256 intermediateLastUpdated) = _getPrice(_sources[i]);
            latestAnswer = latestAnswer * intermediateAnswer / 10 ** 8;
            if (intermediateLastUpdated < lastUpdated) lastUpdated = intermediateLastUpdated;
        }
    }

    /// @dev Fetch price for an asset from Chainlink fixed to 8 decimals
    /// @param _source Chainlink aggregator
    /// @return latestAnswer Price of the asset fixed to 8 decimals
    /// @return lastUpdated Last updated timestamp
    function _getPrice(address _source) internal view returns (uint256 latestAnswer, uint256 lastUpdated) {
        uint8 decimals = IChainlink(_source).decimals();
        int256 intLatestAnswer;
        (, intLatestAnswer,, lastUpdated,) = IChainlink(_source).latestRoundData();
        latestAnswer = intLatestAnswer < 0 ? 0 : uint256(intLatestAnswer);
        if (decimals < 8) latestAnswer *= 10 ** (8 - decimals);
        if (decimals > 8) latestAnswer /= 10 ** (decimals - 8);
    }
}
