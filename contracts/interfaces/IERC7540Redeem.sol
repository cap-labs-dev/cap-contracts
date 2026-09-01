// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC7540Redeem
/// @notice IERC7540Redeem is required for ERC165 support of the ERC7540 async redemption standard.
interface IERC7540Redeem {
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
}
