// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC7575 } from "./IERC7575.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IERC7540AsyncRedeem
/// @notice IERC7540AsyncRedeem is the interface for the ERC7540 async redemption compatible ERC4626 vaults.
interface IERC7540AsyncRedeem is IERC4626, IERC7575 {
    /// @dev Emitted when `sender` has locked `shares`, owned by `owner`, in the Vault to request a redemption.
    /// `controller` controls this request.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @dev Emitted when a redeem request is cancelled
    /// `controller` controls this request.
    event CancelRedeem(address indexed controller, uint256 indexed requestId, address receiver, uint256 shares);

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

    /// @dev Assumes control of shares from sender into the Vault and submits a Request for asynchronous redeem.
    ///
    /// - MUST support a redeem Request flow where the control of shares is taken from sender directly
    ///   where msg.sender has ERC-20 approval over the shares of owner.
    /// - MUST revert if all shares cannot be requested for redeem.
    ///
    /// @param shares the amount of shares to be redeemed to transfer from owner
    /// @param controller the controller of the request who will be able to operate the request
    /// @param owner the source of the shares to be redeemed
    /// @return requestId the id of the request
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @dev Returns the amount of requested shares in Pending state.
    ///
    /// - MUST NOT include any shares in Claimable state for redeem or withdraw.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT revert unless due to integer overflow caused by an unreasonably large input.
    /// @param requestId the id of the request
    /// @param controller the controller of the request
    /// @return pendingShares the amount of pending shares
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @dev Returns the amount of requested shares in Claimable state for the controller to redeem or withdraw.
    ///
    /// - MUST NOT include any shares in Pending state for redeem or withdraw.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT revert unless due to integer overflow caused by an unreasonably large input.
    /// @param requestId the id of the request
    /// @param controller the controller of the request
    /// @return claimableShares the amount of claimable shares
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);

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

    /// @notice Get the number of shares available to be instantly redeemed, taking into account the redemption queue
    /// @return unlocked The number of instantly unlocked shares
    function instantUnlockedSupply() external view returns (uint256 unlocked);
}
