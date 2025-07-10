// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IChainlink } from "../../interfaces/IChainlink.sol";
import { IstETH } from "../../interfaces/IstETH.sol";

/// @title wstETH Adapter
/// @author kexley, Cap Labs
/// @notice Prices are sourced from Chainlink and scaled by the ratio of stETH to wstETH
library wstETHAdapter {
    /// @notice Fetch price for an asset from Chainlink fixed to 8 decimals and scaled by the ratio of stETH to wstETH
    /// @param _source Chainlink aggregator for stETH
    /// @param _stETH stETH address
    /// @return latestAnswer Price of the asset fixed to 8 decimals
    /// @return lastUpdated Last updated timestamp
    function price(address _source, address _stETH) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        (latestAnswer, lastUpdated) = _getPrice(_source);
        latestAnswer = latestAnswer * _getRatio(_stETH) / 1 ether;
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

    /// @notice Get the ratio of stETH to wstETH in 18 decimals
    /// @param _stETH stETH address
    /// @return ratio Ratio of stETH to wstETH in 18 decimals
    function _getRatio(address _stETH) internal view returns (uint256 ratio) {
        ratio = IstETH(_stETH).getPooledEthByShares(1 ether);
    }
}
