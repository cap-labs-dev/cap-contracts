// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";

/// @title ITranche
/// @author kexley, Cap Labs
/// @notice Interface for Tranche contract
interface ITranche is IERC7540AsyncRedeem {
    /// @notice Vesting period must be non-zero, as it is a divisor in premium accrual
    error InvalidVestingPeriod();

    /// @notice Emitted when assets are slashed
    /// @param recipient The recipient of the slashed assets
    /// @param assets The amount of assets slashed
    /// @param value The value of the slashed assets in USD (18 decimals)
    event Slashed(address indexed recipient, uint256 assets, uint256 value);

    /// @notice Emitted when premium is claimed
    /// @param user The user who claimed the premium
    /// @param recipient The recipient of the premium
    /// @param amount The amount of premium claimed
    event Claimed(address indexed user, address indexed recipient, uint256 amount);

    /// @notice Emitted when the premium vesting period is set
    /// @param vestingPeriod The new vesting period
    event SetVestingPeriod(uint256 vestingPeriod);

    /// @notice Initialize the tranche
    /// @param authority The access manager address
    /// @param asset The asset to underwrite
    /// @param name The tranche name
    /// @param symbol The tranche symbol
    /// @param market The market this tranche underwrites
    /// @param vault The vault holding tranche assets
    /// @param oracle The oracle used for price feeds
    function initialize(
        address authority,
        address asset,
        string memory name,
        string memory symbol,
        address market,
        address vault,
        address oracle
    ) external;

    /// @notice Slash the tranche's assets worth a given value
    /// @dev The value is converted to an asset amount at the oracle price, then capped by the
    /// tranche's holdings, so the returned value never exceeds the requested value
    /// @param value The value to slash in USD (18 decimals)
    /// @param recipient The recipient of the slashed assets
    /// @return slashedValue The value slashed in USD (18 decimals)
    function slash(uint256 value, address recipient) external returns (uint256 slashedValue);

    /// @notice Set the whitelist for a depositor
    /// @param account The account to update
    /// @param allowed Whether the account may deposit
    function setWhitelist(address account, bool allowed) external;

    /// @notice Set the premium vesting period
    /// @param vestingPeriod The new vesting period
    function setVestingPeriod(uint256 vestingPeriod) external;

    /// @notice Notify new premium received and start a vesting epoch
    function notifyPremium() external;

    /// @notice Claim vested premium for the caller
    /// @param recipient The address to receive the premium
    /// @return premium The amount of premium claimed
    function claim(address recipient) external returns (uint256 premium);

    /// @notice Check if an account is whitelisted
    /// @param account The account to check
    /// @return allowed Whether the account is whitelisted
    function whitelisted(address account) external view returns (bool allowed);

    /// @notice Get the market this tranche underwrites
    function market() external view returns (address);

    /// @notice Get the vault holding tranche assets
    function vault() external view returns (address);

    /// @notice Get the stablecoin used for premium payments
    function stablecoin() external view returns (address);

    /// @notice Get the oracle used for price feeds
    function oracle() external view returns (address);

    /// @notice Get the premium vesting period
    function vestingPeriod() external view returns (uint256);

    /// @notice Get the end of the current vesting epoch
    function periodEnd() external view returns (uint256);

    /// @notice Get the accumulated premium per share
    function premiumPerShare() external view returns (uint256);

    /// @notice Get the timestamp of the last premium accrual update
    function lastPremiumUpdate() external view returns (uint256);

    /// @notice Get pending premium for an account
    /// @param user The account to query
    function pendingPremium(address user) external view returns (uint256);

    /// @notice Get the premium still vesting in the current epoch
    function vested() external view returns (uint256);

    /// @notice Get claimable premium for an account
    /// @param user The account to query
    /// @return premium The claimable premium
    function claimable(address user) external view returns (uint256 premium);

    /// @notice Total assets held for this tranche in the vault
    /// @dev Overrides IERC4626: returns ERC6909 balance in the vault, not underlying held by this contract
    /// @return assets The tranche asset balance
    function totalAssets() external view returns (uint256 assets);

    /// @notice Maximum deposit for a receiver
    /// @dev Overrides IERC4626: returns unlimited assets only for whitelisted accounts
    /// @param receiver The account that would receive shares
    /// @return maxAssets The maximum deposit amount
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Maximum mint for a receiver
    /// @dev Overrides IERC4626: returns unlimited shares only for whitelisted accounts
    /// @param receiver The account that would receive shares
    /// @return maxShares The maximum mint amount
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Shares available for redemption excluding market-locked assets
    /// @dev Overrides IERC7540AsyncRedeem unlockedSupply
    /// @return unlocked Shares not locked by the market
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the total capital value of the tranche in USD (18 decimals)
    /// @return capital The total capital value in USD
    function totalCapital() external view returns (uint256 capital);

    /// @notice Get the active capital value of the tranche in USD (18 decimals)
    /// @return capital The active capital value in USD
    function activeCapital() external view returns (uint256 capital);
}
