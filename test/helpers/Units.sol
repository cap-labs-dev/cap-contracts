// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @dev Small, test-only helpers for readability (no side effects).
library Units {
    function usd8(uint256 dollars) internal pure returns (uint256) {
        return dollars * 1e8;
    }

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 1e27;
    }
}

