// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IStablecoin
/// @author kexley, Cap Labs
/// @notice Interface for Stablecoin vault accounting
interface IStablecoin {
    /// @notice Emitted when credit-backed tokens are minted
    /// @param to The recipient
    /// @param amount The amount minted
    event MintCreditBacked(address indexed to, uint256 amount);

    /// @notice Emitted when credit-backed tokens are burned
    /// @param from The account burned from
    /// @param amount The amount burned
    event BurnCreditBacked(address indexed from, uint256 amount);

    /// @notice Emitted when bad debt increases
    /// @param amount The amount of bad debt added
    event BadDebtIncreased(uint256 amount);

    /// @notice Emitted when bad debt is reduced
    /// @param owner The account whose redemption reduced bad debt
    /// @param amount The amount of bad debt reduced
    event BadDebtReduced(address indexed owner, uint256 amount);

    /// @notice Initialize the stablecoin
    /// @param authority The access manager address
    /// @param asset The underlying asset address
    /// @param name The token name
    /// @param symbol The token symbol
    /// @param uri The URI for ERC1155 redemption receipt tokens
    /// @param irm The interest rate model address
    function initialize(
        address authority,
        address asset,
        string memory name,
        string memory symbol,
        string memory uri,
        address irm
    ) external;

    /// @notice Mint credit-backed tokens for a borrow or reward
    /// @param to The recipient
    /// @param amount The amount to mint
    function mintCreditBacked(address to, uint256 amount) external;

    /// @notice Burn credit-backed tokens on repay or liquidation
    /// @param from The account to burn from
    /// @param amount The amount to burn
    function burnCreditBacked(address from, uint256 amount) external;

    /// @notice Increase bad debt to socialize losses
    /// @param badDebt The amount of bad debt to add
    function increaseBadDebt(uint256 badDebt) external;

    /// @notice Get the current bad debt
    function badDebt() external view returns (uint256 debt);

    /// @notice Get the underlying asset decimals
    function underlyingDecimals() external view returns (uint8);

    /// @notice Get the interest rate model address
    function irm() external view returns (address);

    /// @notice Get the credit-backed token supply
    function creditBackedSupply() external view returns (uint256);

    /// @notice Total assets backing redemptions after bad debt is excluded
    /// @dev Overrides IERC4626: returns share supply minus bad debt, not underlying token balance
    /// @return assets Total redeemable assets in share units
    function totalAssets() external view returns (uint256 assets);

    /// @notice Preview the shares minted for a deposit at the fixed 1:1 exchange rate
    /// @dev Overrides IERC4626 preview to scale from underlying decimals up to 18-decimal shares
    /// @param assets The asset amount to deposit
    /// @return shares The share amount minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview the assets required to mint shares at the fixed 1:1 exchange rate
    /// @dev Overrides IERC4626 preview to scale from 18-decimal shares down to underlying decimals
    /// @param shares The share amount to mint
    /// @return assets The asset amount required
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Share token decimals
    /// @dev Overrides IERC4626/IERC20Metadata: stablecoin shares always use 18 decimals
    function decimals() external view returns (uint8);

    /// @notice Shares available for redemption excluding credit-backed supply
    /// @dev Overrides IERC7540AsyncRedeem unlockedSupply
    /// @return unlocked Shares not reserved for outstanding borrows
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the utilization rate of credit-backed supply
    /// @return rate The utilization rate in ray decimals
    function utilizationRate() external view returns (uint256 rate);
}
