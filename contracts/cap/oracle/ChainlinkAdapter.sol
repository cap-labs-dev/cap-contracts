// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IChainlink } from "../../interfaces/IChainlink.sol";

/// @title ChainlinkAdapter
/// @author kexley, Cap Labs
/// @notice Prices one Chainlink feed
/// @dev Does not inspect legacy `minAnswer` or `maxAnswer` clamps because supported feeds may not
/// publish active bounds. Feed onboarding must verify clamp behavior, especially for L2 feeds.
library ChainlinkAdapter {
    /// @dev Matches {IOracle-DECIMALS}
    uint8 private constant DECIMALS = 18;

    /// @notice Get the price from a Chainlink feed, normalised to 18 decimals
    /// @dev Zero if the answer is not positive
    /// @param source The Chainlink feed
    /// @return latestAnswer The price of the asset fixed to 18 decimals, or zero
    /// @return lastUpdated When the feed last wrote an answer
    function price(address source) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        int256 answer;
        (, answer,, lastUpdated,) = IChainlink(source).latestRoundData();
        if (answer <= 0) return (0, lastUpdated);

        // casting to 'uint256' is safe because answer <= 0 has already returned
        // forge-lint: disable-next-line(unsafe-typecast)
        latestAnswer = uint256(answer);

        uint8 decimals = IChainlink(source).decimals();
        if (decimals < DECIMALS) latestAnswer *= 10 ** (DECIMALS - decimals);
        else latestAnswer /= 10 ** (decimals - DECIMALS);
    }
}
