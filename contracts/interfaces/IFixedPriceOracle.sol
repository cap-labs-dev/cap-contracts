// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IFixedPriceOracle
/// @author kexley, Cap Labs
/// @notice Interface for the fixed price oracle
interface IFixedPriceOracle {
    /// @notice Get the fixed price
    /// @return fixedPrice Fixed price ($1 in 8 decimals)
    /// @return lastUpdated Last updated timestamp
    function price() external view returns (uint256 fixedPrice, uint256 lastUpdated);
}
