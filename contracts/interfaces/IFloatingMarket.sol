// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "./IBaseMarket.sol";

/// @title IFloatingMarket
/// @author kexley, Cap Labs
/// @notice Interface for the floating interest rate market
interface IFloatingMarket is IBaseMarket {
    /// @notice The scaled amount is zero
    error InvalidScaledAmount();

    /// @notice Initialize the market
    /// @param authority The access manager address
    /// @param registry The registry providing shared market configuration
    /// @param name The name of the market
    function initialize(address authority, address registry, string memory name) external;

    /// @notice Borrow assets from the market
    /// @dev `actualPrincipal` is the rise in {totalDebt} and is at most `principal`.
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets, in stablecoin units (18 decimals)
    /// @return actualPrincipal The actual principal amount of the borrowed assets, in stablecoin units (18 decimals)
    function borrow(address recipient, uint256 principal) external returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @dev `type(uint256).max` clears in full
    /// @param amount The amount of assets to repay, in stablecoin units (18 decimals)
    /// @return repaid The actual amount of assets repaid, in stablecoin units (18 decimals)
    function repay(uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate, in stablecoin units (18 decimals)
    /// @return repaid The actual amount of assets repaid, in stablecoin units (18 decimals)
    /// @return valueSlashed The USD value of collateral delivered, 18 decimals, possibly across tokens
    function liquidate(address recipient, uint256 amount) external returns (uint256 repaid, uint256 valueSlashed);

    /// @notice Charge the accrued premium
    function chargePremium() external;

    /// @notice Write off {unrecoverableDebt} as bad debt
    /// @dev The market must be unhealthy before the write-off. Clears the representable shortfall
    /// without slashing collateral. Remaining debt may be healthy, so continued liquidatability
    /// is not guaranteed. Borrowing remains subject to {creditLimit}; the market is not paused.
    /// @return amount The amount of debt written off, in stablecoin units (18 decimals)
    function writeOff() external returns (uint256 amount);

    /// @notice Get the liquidity and underwriter premiums
    /// @return liquidityPremium The liquidity premium, in stablecoin units (18 decimals)
    /// @return underwriterPremium The underwriter premium, in stablecoin units (18 decimals)
    function premium() external view returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the liquidity and underwriter premium indexes
    /// @dev Liquidity grows as `oldLocal × (newGlobal / oldGlobal)^multiplier`, subject to
    /// fixed-point rounding. Same-block reads return the last checkpoint.
    /// @return liquidityIndex The market-local liquidity index in ray decimals
    /// @return underwriterIndex The underwriter index in ray decimals
    function premiumIndices() external view returns (uint256 liquidityIndex, uint256 underwriterIndex);

    /// @notice Get the combined debt index
    /// @return combinedIndex The combined debt index in ray decimals
    function index() external view returns (uint256 combinedIndex);
}
