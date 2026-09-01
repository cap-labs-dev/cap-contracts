// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title AssetId
/// @author kexley
/// @notice AssetId is a library that converts between asset addresses and ERC6909 token IDs
library AssetId {
    /// @dev Convert an ERC20 address to an ERC6909 token id
    function toId(address token) internal pure returns (uint256 id) {
        id = uint160(token);
    }

    /// @dev Convert an ERC6909 token id back to an ERC20 address
    function toAsset(uint256 id) internal pure returns (address token) {
        // casting to 'uint160' is safe because ids are always address-derived via toId
        // forge-lint: disable-next-line(unsafe-typecast)
        token = address(uint160(id));
    }
}
