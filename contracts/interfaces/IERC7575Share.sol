// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IERC7575Share
/// @notice ERC-7575 share-to-vault lookup. {IERC165-supportsInterface} id is `0xf815c03d`.
interface IERC7575Share {
    /// @notice Get the vault that issues this share token for `asset`
    /// @dev Zero when this share token has no vault for `asset`.
    /// @param asset The underlying asset
    /// @return vaultAddress The vault for `asset`
    function vault(address asset) external view returns (address vaultAddress);
}
