// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";

/// @title ITranche
/// @author kexley, Cap Labs
/// @notice Interface for Tranche contract
interface ITranche is IERC7540AsyncRedeem {
    /// @notice The oracle reported a zero price
    error InvalidPrice();

    /// @notice The caller is not this tranche's market
    error InvalidMarket();

    /// @notice Emitted when assets are slashed
    /// @param recipient The recipient of the slashed assets
    /// @param assets The amount of assets slashed
    /// @param value The value of the slashed assets in USD (18 decimals)
    event Slashed(address indexed recipient, uint256 assets, uint256 value);

    /// @notice Emitted once when a slash retires the tranche
    event Killed();

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

    /// @notice Slash assets worth `value`, capped by holdings
    /// @dev Caller must be this tranche's market
    /// @param value The value to slash in USD (18 decimals)
    /// @param recipient The recipient of the slashed assets
    /// @return slashedValue The value slashed in USD (18 decimals)
    function slash(uint256 value, address recipient) external returns (uint256 slashedValue);

    /// @notice Fold premium into the remainder
    /// @param premium The premium being funded
    function fund(uint256 premium) external;

    /// @notice Get the market this tranche underwrites
    /// @return The market address
    function market() external view returns (address);

    /// @notice Get the vault holding tranche assets
    /// @return The vault address
    function vault() external view returns (address);

    /// @notice Get the oracle used for price feeds
    /// @return The oracle address
    function oracle() external view returns (address);

    /// @notice Whether a slash has retired the tranche
    /// @dev Latched below 1% of par. Closes deposits.
    /// @return Whether the tranche has been retired
    function killed() external view returns (bool);

    /// @notice Total assets held for this tranche in the vault
    /// @dev Vault ERC6909 balance, not tokens held here.
    /// @return assets The tranche asset balance
    function totalAssets() external view returns (uint256 assets);

    /// @notice Maximum deposit for a receiver
    /// @dev Unlimited until killed, then zero. Admission is on {deposit}, not here.
    /// @param receiver The account that would receive shares
    /// @return maxAssets The maximum deposit amount
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Maximum mint for a receiver
    /// @dev Same gate as {maxDeposit}.
    /// @param receiver The account that would receive shares
    /// @return maxShares The maximum mint amount
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Shares available for redemption excluding market-locked assets
    /// @return unlocked Shares not locked by the market
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the total capital value of the tranche in USD (18 decimals)
    /// @return capital The total capital value in USD
    function totalCapital() external view returns (uint256 capital);

    /// @notice Get the active capital value of the tranche in USD (18 decimals)
    /// @return capital The active capital value in USD
    function activeCapital() external view returns (uint256 capital);
}
