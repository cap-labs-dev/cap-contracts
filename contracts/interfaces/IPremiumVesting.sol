// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPremiumVesting
/// @author kexley, Cap Labs
/// @notice Shared premium vesting surface for {Tranche}, {Underwriter} and {Stablecoin}
interface IPremiumVesting {
    /// @notice Emitted when vested premium is claimed
    /// @param user The account whose entitlement was settled
    /// @param recipient The address that received the premium
    /// @param amount The amount paid
    event Claimed(address indexed user, address indexed recipient, uint256 amount);

    /// @notice Emitted when an account opts in to earn vested premium
    /// @param account The account that opted in
    event OptIn(address indexed account);

    /// @notice Emitted when an account opts out of earning vested premium
    /// @param account The account that opted out
    event OptOut(address indexed account);

    /// @notice Claim vested premium for the caller
    /// @param recipient The address to receive the premium
    /// @return premium The amount paid, clamped to the stablecoin actually held
    function claim(address recipient) external returns (uint256 premium);

    /// @notice Opt the caller into earning vested premium
    /// @dev Adds their balance to the staked supply.
    function optIn() external;

    /// @notice Opt the caller out of earning vested premium
    /// @dev Banks earned premium, then drops their balance from the staked supply.
    function optOut() external;

    /// @notice Whether an account earns vested premium
    /// @param account The account to query
    /// @return opted Whether the account has opted in
    function optedIn(address account) external view returns (bool opted);

    /// @notice The stablecoin premium is paid in
    /// @return token The premium token
    function stablecoin() external view returns (address token);

    /// @notice Vesting time constant (twelve hours)
    /// @return period The vesting time constant
    function vestingPeriod() external view returns (uint256 period);

    /// @notice Premium that has become available to claim since the last accrual
    /// @return amount The vested premium not yet written to `perShare`
    function vested() external view returns (uint256 amount);

    /// @notice Premium still locked, not yet vested
    /// @return amount The remainder after the unwritten vest
    function remaining() external view returns (uint256 amount);

    /// @notice Instantaneous release rate, remaining / period
    /// @dev Accrual uses the exponential weight, not this times elapsed.
    /// @return perSecond The current remainder divided by the vesting period
    function premiumPerSecond() external view returns (uint256 perSecond);

    /// @notice Get the timestamp of the last premium accrual update
    /// @return timestamp The last time vested premium was written to `perShare`
    function lastPremiumUpdate() external view returns (uint256 timestamp);

    /// @notice Get the accumulated premium per share in ray decimals
    /// @return perShare Cumulative premium released per staked share
    function premiumPerShare() external view returns (uint256 perShare);

    /// @notice Get pending premium already settled for an account
    /// @param user The account to query
    /// @return premium Premium banked at the last checkpoint and not yet collected
    function pendingPremium(address user) external view returns (uint256 premium);

    /// @notice Calculated premium entitlement for an account
    /// @dev Not the amount {claim} will pay. Payment is capped by the stablecoin this contract holds.
    /// @param user The account to query
    /// @return premium The calculated entitlement, uncapped by holdings
    function claimable(address user) external view returns (uint256 premium);

    /// @notice Sum of opted-in balances
    /// @return supply The number of shares that earn
    function stakedSupply() external view returns (uint256 supply);
}
