// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IWrapper
/// @author kexley, Cap Labs
/// @notice Interface for the ERC-4626 vault that holds a stablecoin and claims its vested premium
/// @dev Fresh deployments seed unredeemable shares via {DeadShares}.
/// Deposits and mints must issue at least one share or revert with {ZeroShares}.
/// A deposit preview can still return zero when the asset amount rounds below one share.
interface IWrapper is IERC4626 {
    /// @notice The deposit or mint produces zero shares
    error ZeroShares();

    /// @notice Initialize the wrapper
    /// @dev `reinitializer(2)` so a v1 proxy can be upgraded onto this implementation and run
    /// initialize again. Fresh proxies take the same path.
    /// @param authority The access manager address
    /// @param asset The underlying {IPremiumVesting} token, the stablecoin
    function initialize(address authority, address asset) external;

    /// @notice Get the total assets including vested premium the vault can claim from its underlying
    /// @dev Adds {IPremiumVesting-claimable} for this contract.
    /// @return assets The vault asset balance plus unclaimed vested premium, in stablecoin units (18 decimals)
    function totalAssets() external view returns (uint256 assets);

    /// @notice Get the decimals of the underlying asset
    /// @return decimals The decimals of the underlying asset
    function decimals() external view returns (uint8 decimals);
}
