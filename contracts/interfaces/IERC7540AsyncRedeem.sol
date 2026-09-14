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

    /// @dev Emitted when control of a request moves to another controller.
    event TransferRequest(address indexed from, address indexed to, uint256 indexed requestId);

    /// @dev A settlement burned `shares` from `requestId`. `remainingShares` is what is still queued.
    ///      {Withdraw} still reports the aggregate asset payment; this names the receipt.
    event RedeemRequestConsumed(
        uint256 indexed requestId, address indexed controller, uint256 shares, uint256 remainingShares
    );

    /// @dev Revert when attempting to request a redeem with zero shares.
    error ZeroShares();

    /// @dev Revert when attempting to request a redeem for the zero address.
    error ZeroAddress();

    /// @dev Revert when redeem request is not found for a given requestId and controller.
    error RedeemRequestNotFound(uint256 requestId, address controller);

    /// @dev Revert when the caller is not authorized for the requested operation.
    error NotAuthorized(address caller);

    /// @dev ERC-7540 async redeem vaults must revert {previewRedeem} and {previewWithdraw}.
    error PreviewNotSupported();

    /// @dev FIFO consume did not burn every share the quote required.
    error IncompleteClaim(uint256 consumed, uint256 requested);

    /// @dev The settlement paid a different asset amount than the caller requested.
    error InexactPayout(uint256 paid, uint256 requested);

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

    /// @notice Claim previously requested shares on a single request
    /// @dev Caller must be `controller` or its operator. ERC-20 allowance is insufficient.
    ///      Limited to currently claimable shares on this request and {unlockedSupply}.
    ///      Pays `convertToAssets(shares)` (floored). There is no redemption window.
    /// @param requestId The request to settle
    /// @param shares Shares to claim
    /// @param receiver Asset recipient
    /// @param controller Request controller, not an instant share-balance owner
    /// @return assets Assets paid
    function redeem(uint256 requestId, uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claim a previously requested redemption by asset amount on a single request
    /// @dev Caller must be `controller` or its operator. ERC-20 allowance is insufficient.
    ///      Limited to currently claimable shares on this request and {unlockedSupply}.
    ///      Burns the ceil-quoted shares for `assets`.
    /// @param requestId The request to settle
    /// @param assets Assets to pay
    /// @param receiver Asset recipient
    /// @param controller Request controller, not an instant share-balance owner
    /// @return shares Shares burned
    function withdraw(uint256 requestId, uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Shares not sitting in the redemption queue
    /// @return supply `totalSupply - redemptionQueue`
    function activeSupply() external view returns (uint256 supply);

    /// @notice Asset quote for {activeSupply}
    /// @dev `convertToAssets(activeSupply())`. Not a separable physical reserve balance; a
    ///      nonlinear conversion (for example {IStablecoin} under a shortfall) can make this
    ///      differ from `totalAssets - convertToAssets(redemptionQueue)`.
    /// @return assets The exit quote of the unqueued shares
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
