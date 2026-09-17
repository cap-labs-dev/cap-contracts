// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPremiumVesting
/// @author kexley, Cap Labs
/// @notice Interface for the shared premium vesting surface used by {Tranche}, {Underwriter} and {Stablecoin}
interface IPremiumVesting {
    /// @notice Emitted when premium is added to the remainder
    /// @param source The caller that funded
    /// @param amount The premium added, in stablecoin units (18 decimals)
    event Fund(address indexed source, uint256 amount);

    /// @notice Emitted when vested premium is claimed
    /// @param user The account whose entitlement was settled
    /// @param recipient The address that received the premium
    /// @param amount The amount paid, in stablecoin units (18 decimals)
    event Claimed(address indexed user, address indexed recipient, uint256 amount);

    /// @notice Emitted when an account opts in to earn vested premium
    /// @param account The account that opted in
    event OptIn(address indexed account);

    /// @notice Emitted when an account opts out of earning vested premium
    /// @param account The account that opted out
    event OptOut(address indexed account);

    /// @notice Claim vested premium for the caller
    /// @dev Pays the calculated entitlement, clamped to spendable holdings. Unpaid remainder is
    /// not preserved. cUSD spendable excludes shares in the redemption queue.
    /// @param recipient The address to receive the premium
    /// @return premium The amount paid, in stablecoin units (18 decimals), clamped to spendable holdings
    function claim(address recipient) external returns (uint256 premium);

    /// @notice Opt the caller into earning vested premium
    /// @dev Adds their balance to the staked supply.
    function optIn() external;

    /// @notice Opt the caller out of earning vested premium
    /// @dev Banks earned premium, then drops their balance from the staked supply.
    function optOut() external;

    /// @notice Get whether an account earns vested premium
    /// @param account The account to query
    /// @return opted Whether the account has opted in
    function optedIn(address account) external view returns (bool opted);

    /// @notice Get the stablecoin used for premium
    /// @return token The premium token
    function stablecoin() external view returns (address token);

    /// @notice Get the vesting time constant
    /// @return period The vesting time constant
    function vestingPeriod() external view returns (uint256 period);

    /// @notice Get the premium that has become available to claim since the last accrual
    /// @dev Zero when nobody is earning, matching a freeze.
    /// @return amount The vested premium not yet written to `perShare`, in stablecoin units (18 decimals)
    function vested() external view returns (uint256 amount);

    /// @notice Get the premium still locked, not yet vested
    /// @dev Equals the stored remainder while nobody is earning.
    /// @return amount The remainder after the unwritten vest, in stablecoin units (18 decimals)
    function remaining() external view returns (uint256 amount);

    /// @notice Get the instantaneous release rate, remaining / period
    /// @dev Accrual uses the exponential weight, not this times elapsed.
    /// @return perSecond The current remainder divided by the vesting period, in stablecoin units (18 decimals)
    function premiumPerSecond() external view returns (uint256 perSecond);

    /// @notice Get the timestamp of the last premium accrual update
    /// @return timestamp The last time vested premium was written to `perShare`
    function lastPremiumUpdate() external view returns (uint256 timestamp);

    /// @notice Get the accumulated premium per share in ray decimals
    /// @return perShare The cumulative premium released per staked share, in ray decimals
    function premiumPerShare() external view returns (uint256 perShare);

    /// @notice Get pending premium already settled for an account
    /// @param user The account to query
    /// @return premium The premium banked at the last checkpoint and not yet collected, in stablecoin units (18 decimals)
    function pendingPremium(address user) external view returns (uint256 premium);

    /// @notice Get the calculated premium entitlement for an account
    /// @dev Not the amount {claim} will pay. Payment is capped by the stablecoin this contract holds.
    /// @param user The account to query
    /// @return premium The calculated entitlement, in stablecoin units (18 decimals), uncapped by holdings
    function claimable(address user) external view returns (uint256 premium);

    /// @notice Get the sum of opted-in balances
    /// @return supply The number of shares that earn
    function stakedSupply() external view returns (uint256 supply);
}
