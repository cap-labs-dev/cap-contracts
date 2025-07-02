// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IAaveDataProvider
/// @author kexley, Cap Labs
/// @notice Interface for the AaveDataProvider contract
interface IAaveDataProvider {
    /// @notice Get the reserve data for an asset
    /// @param asset The asset address
    /// @return unbacked The unbacked amount of the asset
    /// @return accruedToTreasuryScaled The accrued to treasury scaled amount of the asset
    /// @return totalAToken The total amount of aTokens of the asset
    /// @return totalStableDebt The total amount of stable debt of the asset
    /// @return totalVariableDebt The total amount of variable debt of the asset
    /// @return liquidityRate The liquidity rate of the asset
    /// @return variableBorrowRate The variable borrow rate of the asset
    /// @return stableBorrowRate The stable borrow rate of the asset
    /// @return averageStableBorrowRate The average stable borrow rate of the asset
    /// @return liquidityIndex The liquidity index of the asset
    /// @return variableBorrowIndex The variable borrow index of the asset
    /// @return lastUpdateTimestamp The last update timestamp of the asset
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );
}
