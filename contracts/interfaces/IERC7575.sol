// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC7575
/// @notice ERC-4626 vault methods plus {share}. Flattened so {IERC165-supportsInterface} id is `0x2f0a18c5`.
/// @dev Do not inherit this next to {IERC4626}: same selectors, different types, override diamond.
///      Cap async vaults specialize {maxRedeem}, {maxWithdraw}, {redeem}, and {withdraw} on
///      {ERC7540AsyncRedeem}: those claim requested redemptions for a controller, not an
///      instant share balance. Use that NatSpec, not the generic wording below.
interface IERC7575 {
    /// @notice Underlying asset the vault accounts, deposits, and withdraws
    /// @return assetTokenAddress The ERC-20 asset
    function asset() external view returns (address assetTokenAddress);

    /// @notice Share token representing vault equity
    /// @dev ERC-7575 extra versus ERC-4626, where the vault is its own share token.
    /// @return shareTokenAddress The ERC-20 share token
    function share() external view returns (address shareTokenAddress);

    /// @notice Underlying assets managed by the vault
    /// @return totalManagedAssets The asset amount
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Shares that would be exchanged for `assets` at the current rate
    /// @param assets The asset amount
    /// @return shares The share amount
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Assets that would be exchanged for `shares` at the current rate
    /// @param shares The share amount
    /// @return assets The asset amount
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Maximum assets `receiver` may deposit
    /// @param receiver The share recipient
    /// @return maxAssets The deposit limit, or `type(uint256).max` if unlimited
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Shares a deposit of `assets` would mint at current conditions
    /// @param assets The asset amount
    /// @return shares The share amount
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Deposit `assets` and mint shares to `receiver`
    /// @param assets The asset amount
    /// @param receiver The share recipient
    /// @return shares The shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Maximum shares `receiver` may mint
    /// @param receiver The share recipient
    /// @return maxShares The mint limit, or `type(uint256).max` if unlimited
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Assets a mint of `shares` would pull at current conditions
    /// @param shares The share amount
    /// @return assets The asset amount
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Mint `shares` to `receiver` and pull the required assets
    /// @param shares The share amount
    /// @param receiver The share recipient
    /// @return assets The assets deposited
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Maximum assets `owner` may withdraw
    /// @param owner The share holder
    /// @return maxAssets The withdraw limit
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Shares a withdrawal of `assets` would burn at current conditions
    /// @param assets The asset amount
    /// @return shares The share amount
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Withdraw `assets` to `receiver` and burn `owner`'s shares
    /// @param assets The asset amount
    /// @param receiver The asset recipient
    /// @param owner The share holder
    /// @return shares The shares burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Maximum shares `owner` may redeem
    /// @param owner The share holder
    /// @return maxShares The redeem limit
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Assets a redemption of `shares` would pay at current conditions
    /// @param shares The share amount
    /// @return assets The asset amount
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Redeem `shares` from `owner` and pay assets to `receiver`
    /// @param shares The share amount
    /// @param receiver The asset recipient
    /// @param owner The share holder
    /// @return assets The assets paid
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
