// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC7540Redeem
/// @author kexley
/// @notice ERC-7540 asynchronous redemption
/// @dev Only the three methods the EIP uses. Cap extras live on {IERC7540AsyncRedeem}.
///      {ITranche} claimability views consult {unlockedSupply} and may revert
///      {ITranche-InvalidPrice} when that read needs a price and the oracle is down.
///      That is a documented deviation from the EIP's non-revert promise. Other Cap
///      vaults keep the EIP rule.
interface IERC7540Redeem {
    /// @dev `sender` locked `shares` owned by `owner`. `controller` controls the request.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @dev Assumes control of `shares` from `owner` and submits a Request for asynchronous redeem.
    ///
    /// - MUST support a redeem Request flow where the control of shares is taken from sender directly
    ///   where msg.sender has ERC-20 approval over the shares of owner.
    /// - MUST revert if all shares cannot be requested for redeem.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @dev Requested `shares` in Pending state for (`requestId`, `controller`).
    ///
    /// - MUST NOT include any shares in Claimable state.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT revert unless due to integer overflow caused by an unreasonably large input,
    ///   except a Cap {ITranche} may revert {ITranche-InvalidPrice} as noted above.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @dev Requested `shares` in Claimable state for (`requestId`, `controller`).
    ///
    /// - MUST NOT include any shares in Pending state.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT revert unless due to integer overflow caused by an unreasonably large input,
    ///   except a Cap {ITranche} may revert {ITranche-InvalidPrice} as noted above.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}
