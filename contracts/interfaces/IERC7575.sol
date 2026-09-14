// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC7575
/// @notice ERC-4626 vault methods plus {share}. Flattened so {IERC165-supportsInterface} id is `0x2f0a18c5`.
/// @dev Do not inherit this next to {IERC4626}: same selectors, different types, override diamond.
interface IERC7575 {
    function asset() external view returns (address assetTokenAddress);

    function share() external view returns (address shareTokenAddress);

    function totalAssets() external view returns (uint256 totalManagedAssets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function maxMint(address receiver) external view returns (uint256 maxShares);

    function previewMint(uint256 shares) external view returns (uint256 assets);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    function maxRedeem(address owner) external view returns (uint256 maxShares);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
