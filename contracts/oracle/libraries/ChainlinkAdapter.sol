// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IChainlink } from "../../interfaces/IChainlink.sol";

/// @title Chainlink Adapter
/// @author kexley, @capLabs
/// @notice Prices are sourced from Chainlink
library ChainlinkAdapter {
    /// @notice Fetch price for an asset from Chainlink fixed to 8 decimals
    /// @param _source Chainlink aggregator
    function price(address _source, address /*_asset*/) external view returns (uint256 latestAnswer) {
        uint8 decimals = IChainlink(_source).decimals();
        latestAnswer = uint256(IChainlink(_source).latestAnswer());
        if (decimals < 8) latestAnswer *= 10 ** (8 - decimals);
        if (decimals > 8) latestAnswer /= 10 ** (decimals - 8);
    }
}
