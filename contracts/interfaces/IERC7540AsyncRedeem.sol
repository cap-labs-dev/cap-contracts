// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540Redeem } from "./IERC7540Redeem.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IERC7540AsyncRedeem
/// @notice Cap async redeem vault: ERC-7540 redeem plus instant exits and request transfer
/// @dev {IERC7575} is the flattened ERC-165 id. Do not inherit it here: it duplicates {IERC4626}.
interface IERC7540AsyncRedeem is IERC7540Redeem, IERC4626 {
    /// @notice Get the address of the share token
    /// @return shareTokenAddress The address of the share token
    function share() external view returns (address shareTokenAddress);

    /// @dev Emitted when a redeem request is cancelled
    /// `controller` controls this request.
    event CancelRedeem(address indexed controller, uint256 indexed requestId, address receiver, uint256 shares);

    /// @dev Emitted when control of a request moves to another controller.
    event TransferRequest(address indexed from, address indexed to, uint256 indexed requestId);

    /// @dev Revert when attempting to request a redeem with zero shares.
    error ZeroShares();

    /// @dev Revert when attempting to request a redeem for the zero address.
    error ZeroAddress();

    /// @dev Revert when redeem request is not found for a given requestId and controller.
    error RedeemRequestNotFound(uint256 requestId, address controller);

    /// @dev Revert when trying to cancel more shares than are pending in the redeem request.
    error CancelExceedsPending(uint256 requestId, address controller, uint256 shares, uint256 pendingShares);

    /// @dev Revert when the caller is not authorized for the requested operation.
    error NotAuthorized(address caller);

    /// @dev Revert when there are no pending shares for the given redeem request.
    error NoPendingShares(uint256 requestId, address controller);

    /// @dev Revert when there are no claimable shares for the given redeem request.
    error NoClaimableShares(uint256 requestId, address controller);

    /// @dev ERC-7540 async redeem vaults must revert {previewRedeem} and {previewWithdraw}.
    error PreviewNotSupported();

    /// @notice Move a request to another controller. Place in the settlement queue is unchanged.
    /// @dev Caller must be the current controller or its operator.
    /// @param requestId The request to transfer
    /// @param to The new controller
    function transferRequest(uint256 requestId, address to) external;

    /// @notice Controller that currently owns a request
    /// @dev Cap extra, not an ERC-7540 method.
    /// @param requestId The request id
    /// @return controller The controller, or zero if the request does not exist
    function controllerOf(uint256 requestId) external view returns (address controller);

    /// @dev Redeem shares from the vault while the redemption window is open
    /// @param requestId The id of the request
    /// @param shares The number of shares to redeem
    /// @param receiver The receiver of the assets
    /// @param controller The controller of the request
    /// @return assets The number of assets redeemed
    function redeem(uint256 requestId, uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @dev Withdraw assets from the vault after requesting a redeem.
    /// @param requestId The id of the request
    /// @param assets The number of assets to withdraw
    /// @param receiver The receiver of the assets
    /// @param controller The controller of the request
    /// @return shares The number of shares withdrawn
    function withdraw(uint256 requestId, uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Get the number of shares not in the redemption queue
    /// @return supply The number of shares not in the redemption queue
    function activeSupply() external view returns (uint256 supply);

    /// @notice Get the number of assets not in the redemption queue
    /// @return assets The number of assets not in the redemption queue
    function activeAssets() external view returns (uint256 assets);

    /// @notice Get the number of shares in the redemption queue
    /// @return queue The number of shares in the redemption queue
    function redemptionQueue() external view returns (uint256 queue);

    /// @notice Get the number of shares not locked
    /// @return unlocked The number of unlocked shares
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Shares available for instant redeem, after the queue
    /// @return unlocked The number of instantly unlocked shares
    function instantUnlockedSupply() external view returns (uint256 unlocked);

    /// @notice Shares {instantRedeem} will accept for `owner`
    /// @param owner The share holder
    /// @return maxShares The instant redeem limit
    function maxInstantRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Assets {instantWithdraw} will accept for `owner`
    /// @param owner The share holder
    /// @return maxAssets The instant withdraw limit
    function maxInstantWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Redeem shares against liquid reserve, without a request
    /// @param shares The shares to burn
    /// @param receiver The asset recipient
    /// @param owner The share holder
    /// @return assets The assets paid
    function instantRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Withdraw assets against liquid reserve, without a request
    /// @param assets The assets to pay
    /// @param receiver The asset recipient
    /// @param owner The share holder
    /// @return shares The shares burned
    function instantWithdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Shares a withdrawal of `assets` would burn, including shortfall pricing
    /// @dev {previewWithdraw} reverts. This is the quote {unlockedSupply} and instant exits use.
    /// @param assets The asset amount
    /// @return shares The share amount
    function quoteWithdraw(uint256 assets) external view returns (uint256 shares);
}
