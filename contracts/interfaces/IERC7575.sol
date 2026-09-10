// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC7575
/// @notice ERC-7575 share-token pointer
interface IERC7575 {
    /// @notice Get the address of the share token
    /// @return shareTokenAddress The address of the share token
    function share() external view returns (address shareTokenAddress);
}
