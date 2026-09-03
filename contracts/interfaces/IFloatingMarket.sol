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
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrow(address recipient, uint256 principal) external returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @dev Debt is held scaled by {index}, so a repayment settles at the largest whole number of
    /// scaled units that does not exceed the amount asked for, and that settled figure is what is
    /// burned. Expect it to come back a wei or two under `amount` at a grown index. An amount too
    /// small to move a single scaled unit clears nothing and reverts with {InvalidScaledAmount}
    /// rather than being taken for a no-op; use {chargePremium} to accrue without repaying.
    /// Passing `type(uint256).max`, or anything at or above the outstanding debt, clears it in full.
    /// @param amount The amount of assets to repay
    /// @return repaid The actual amount of assets repaid
    function repay(uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @dev Settles to a whole number of scaled units the same way {repay} does, so `repaid` can
    /// come back just under the entitlement. Collateral is slashed against `repaid`, not against
    /// the request, so the bonus is paid on exactly the debt that cleared.
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate
    /// @return repaid The actual amount of assets repaid
    /// @return assetsSlashed The amount of assets slashed
    function liquidate(address recipient, uint256 amount) external returns (uint256 repaid, uint256 assetsSlashed);

    /// @notice Charge the accrued premium
    function chargePremium() external;

    /// @notice Write off the market's unrecoverable debt as bad debt
    /// @dev Callable at any time, not just once the tranches are empty, because a liquidation that
    /// is unprofitable never happens and would otherwise let the shortfall compound. The amount is
    /// derived from the tranches rather than supplied: it is {unrecoverableDebt}, the excess of the
    /// debt over what the tranche capital could clear at the liquidation bonus. The stablecoin
    /// records the shortfall and drops it out of the credit-backed supply, and the scaled debt is
    /// re-indexed to the remainder, which stays liquidatable.
    /// @return amount The amount of debt written off
    function writeOff() external returns (uint256 amount);

    /// @notice Get the liquidity and underwriter premiums
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premium() external view returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the liquidity and underwriter premium indexes
    /// @return liquidityIndex The liquidity index
    /// @return underwriterIndex The underwriter index
    function premiumIndices() external view returns (uint256 liquidityIndex, uint256 underwriterIndex);

    /// @notice Get the combined debt index
    /// @return combinedIndex The combined debt index
    function index() external view returns (uint256 combinedIndex);
}
