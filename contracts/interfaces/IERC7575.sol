// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IERC7575
/// @notice IERC7575 is the interface for the ERC7575 standard
interface IERC7575 {
    /// @notice Get the address of the share token
    /// @return shareTokenAddress The address of the share token
    function share() external view returns (address shareTokenAddress);
}
