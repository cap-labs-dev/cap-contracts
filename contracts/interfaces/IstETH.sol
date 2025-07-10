// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title stETH Interface
/// @author kexley, Cap Labs
/// @notice Interface for stETH
interface IstETH {
    /// @notice Get the amount of ETH in the pool for a given amount of stETH
    /// @param shares Amount of stETH
    /// @return amount Amount of ETH in the pool
    function getPooledEthByShares(uint256 shares) external view returns (uint256);
}
