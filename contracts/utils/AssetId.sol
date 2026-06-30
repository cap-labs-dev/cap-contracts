// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title AssetId
/// @author kexley
/// @notice AssetId is a library that converts between asset addresses and ERC6909 token IDs
library AssetId {
    function toId(address token) internal pure returns (uint256 id) {
        id = uint160(token);
    }

    function toAsset(uint256 id) internal pure returns (address token) {
        token = address(uint160(id));
    }
}
