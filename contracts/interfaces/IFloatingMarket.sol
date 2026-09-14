// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "./IBaseMarket.sol";

/// @title IFloatingMarket
/// @author kexley, Cap Labs
/// @notice Interface for floating interest rate market
interface IFloatingMarket is IBaseMarket {
    /// @notice The scaled amount is zero
    error InvalidScaledAmount();

    /// @notice Initialize the market
    /// @param authority The authority of the market
    /// @param registry The registry providing shared market configuration
    /// @param name The name of the market
    function initialize(address authority, address registry, string memory name) external;

    /// @notice Borrow assets from the market
    /// @dev `actualPrincipal` is the rise in {totalDebt} and is at most `principal`.
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrow(address recipient, uint256 principal) external returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @dev `type(uint256).max` clears in full
    /// @param amount The amount of assets to repay
    /// @return repaid The actual amount of assets repaid
    function repay(uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate
    /// @return repaid The actual amount of assets repaid
    /// @return valueSlashed USD value of collateral delivered, 18 decimals, possibly across tokens
    function liquidate(address recipient, uint256 amount) external returns (uint256 repaid, uint256 valueSlashed);

    /// @notice Charge the accrued premium
    function chargePremium() external;

    /// @notice Write off {unrecoverableDebt} as bad debt
    /// @dev The market must be unhealthy. Unrecoverable debt is derived. Remaining debt stays
    /// liquidatable.
    /// @return amount The amount of debt written off
    function writeOff() external returns (uint256 amount);

    /// @notice Get the liquidity and underwriter premiums
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premium() external view returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the liquidity and underwriter premium indexes
    /// @dev Liquidity grows as `oldLocal × (newGlobal / oldGlobal)^multiplier`, subject to
    /// fixed-point rounding. Same-block reads return the last checkpoint.
    /// @return liquidityIndex The market-local liquidity index
    /// @return underwriterIndex The underwriter index
    function premiumIndices() external view returns (uint256 liquidityIndex, uint256 underwriterIndex);

    /// @notice Get the combined debt index
    /// @return combinedIndex The combined debt index
    function index() external view returns (uint256 combinedIndex);
}
