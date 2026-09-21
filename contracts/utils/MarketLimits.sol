// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MarketLimits
/// @notice Shared bounds for market risk parameters
/// @dev Review these bounds together: credit at MAX_LT - MIN_BUFFER must remain below
/// collateral recovery at MAX_LIQUIDATION_BONUS, and MIN_TARGET_HEALTH must exceed
/// MAX_LT * (1 + MAX_LIQUIDATION_BONUS), with ratios expressed as fractions.
library MarketLimits {
    /// @dev Minimum liquidation buffer: ten percentage points, in ray decimals.
    uint256 internal constant MIN_BUFFER = 0.1e27;

    /// @dev Maximum liquidation threshold: 100%, in ray decimals.
    uint256 internal constant MAX_LT = 1e27;

    /// @dev Minimum target health after liquidation, in ray decimals.
    uint256 internal constant MIN_TARGET_HEALTH = 1.25e27;

    /// @dev Maximum collateral bonus per unit of debt liquidated: 10%, in ray decimals.
    uint256 internal constant MAX_LIQUIDATION_BONUS = 0.1e27;
}
