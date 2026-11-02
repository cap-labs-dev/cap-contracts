// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IStakedCapV1
/// @author kexley, Cap Labs
/// @notice Interface for the valuation surface of v1 stcUSD
interface IStakedCapV1 {
    /// @notice Get the assets backing the shares
    /// @dev `storedTotal - lockedProfit()`: profit still releasing, or not yet notified, is left out.
    /// @return total The total assets, in cUSD units (18 decimals)
    function totalAssets() external view returns (uint256 total);
}
