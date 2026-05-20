// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IChainlink } from "../../interfaces/IChainlink.sol";

/// @title FalconX USDC Adapter
/// @author weso, Cap Labs
/// @notice Prices are sourced from FalconX USDC
library FalconXUSDCAdapter {
    /// @notice Fetch price for an asset from FalconX USDC fixed to 8 decimals
    /// @param _source FalconX USDC aggregator
    /// @return latestAnswer Price of the asset fixed to 8 decimals
    /// @return lastUpdated Last updated timestamp is block.timestamp since its a rate oracle
    function price(address _source) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        uint8 decimals = IChainlink(_source).decimals();
        int256 intLatestAnswer;
        lastUpdated = block.timestamp;
        (, intLatestAnswer,,,) = IChainlink(_source).latestRoundData();
        latestAnswer = intLatestAnswer < 0 ? 0 : uint256(intLatestAnswer);
        if (decimals < 8) latestAnswer *= 10 ** (8 - decimals);
        if (decimals > 8) latestAnswer /= 10 ** (decimals - 8);
    }
}
