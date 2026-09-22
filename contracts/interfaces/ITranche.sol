// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";

/// @title ITranche
/// @author kexley, Cap Labs
/// @notice Interface for the ERC-4626 tranche vault
/// @dev Beacon instance. Upgrade via {UpgradeableBeacon-upgradeTo} on the tranche beacon.
/// Deposits and mints must issue at least one share or revert with {ZeroShares}.
/// A deposit preview can still return zero when the asset amount rounds below one share.
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

    /// @notice Emitted when the maximum capital is updated
    /// @param maxCapital The new maximum capital in USD (18 decimals)
    event SetMaxCapital(uint256 maxCapital);

    /// @notice Initialize the tranche
    /// @param authority The access manager address
    /// @param registryAddress The registry that configures access roles
    /// @param asset The asset to underwrite
    /// @param name The tranche name
    /// @param symbol The tranche symbol
    /// @param market The market this tranche underwrites
    /// @param vault The vault holding tranche assets
    /// @param oracle The oracle used for price feeds
    function initialize(
        address authority,
        address registryAddress,
        address asset,
        string memory name,
        string memory symbol,
        address market,
        address vault,
        address oracle
    ) external;

    /// @notice Set the role permitted to deposit
    /// @dev Can be opened to PUBLIC or kept closed.
    /// @param roleId The depositor role id
    function setDepositorRole(uint64 roleId) external;

    /// @notice Set the maximum capital
    /// @dev {capitalLimit} is the `min` of this and {activeCapital}.
    /// @param maxCapital The new maximum capital in USD (18 decimals)
    function setMaxCapital(uint256 maxCapital) external;

    /// @notice Slash assets worth `value`, capped by holdings
    /// @dev Caller must be this tranche's market. Returns the floored USD value of
    /// tokens actually transferred. Empty holdings, or a request that cannot
    /// produce a positive USD output, return 0 so the market can offer the
    /// remainder to the next tranche.
    /// @param value The value to slash in USD (18 decimals)
    /// @param recipient The recipient of the slashed assets
    /// @return slashedValue The value slashed in USD (18 decimals)
    function slash(uint256 value, address recipient) external returns (uint256 slashedValue);

    /// @notice Fold premium into the remainder
    /// @param premium The premium being funded, in stablecoin units (18 decimals)
    function fund(uint256 premium) external;

    /// @notice Get the market this tranche underwrites
    /// @return The market address
    function market() external view returns (address);

    /// @notice Get the registry that configures access roles
    /// @return The registry address
    function registry() external view returns (address);

    /// @notice Get the vault holding tranche assets
    /// @return The vault address
    function vault() external view returns (address);

    /// @notice Get the oracle used for price feeds
    /// @return The oracle address
    function oracle() external view returns (address);

    /// @notice Get whether a slash has retired the tranche
    /// @dev Latched below 1% of par. Closes deposits. The market also stops sending it fresh
    /// premium, so leftover dust cannot keep its weight.
    /// @return Whether the tranche has been retired
    function killed() external view returns (bool);

    /// @notice Get the maximum capital of the tranche in USD (18 decimals)
    /// @return The maximum capital in USD (18 decimals)
    function maxCapital() external view returns (uint256);

    /// @notice Get the capital limit of the tranche in USD (18 decimals)
    /// @dev `min` of {activeCapital} and {maxCapital}. Zero when empty or the cap is zero.
    /// @return limit The capital limit in USD (18 decimals)
    function capitalLimit() external view returns (uint256 limit);

    /// @notice Get the total assets held for this tranche in the vault
    /// @dev Vault ERC6909 balance, not tokens held here.
    /// @return assets The tranche asset balance
    function totalAssets() external view returns (uint256 assets);

    /// @notice Get the maximum deposit for a receiver
    /// @dev Unlimited until killed, then zero. Admission is on {deposit}, not here.
    /// @param receiver The account that would receive shares
    /// @return maxAssets The maximum deposit amount
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Get the maximum mint for a receiver
    /// @dev Same gate as {maxDeposit}.
    /// @param receiver The account that would receive shares
    /// @return maxShares The maximum mint amount
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Get the shares available for redemption excluding market-locked assets
    /// @dev A zero lock does not consult the oracle. A positive lock prices locked
    /// value and may revert {InvalidPrice}. {pendingRedeemRequest} and
    /// {claimableRedeemRequest} read this, which is the documented EIP-7540 deviation.
    /// @return unlocked The shares not locked by the market
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the total capital value of the tranche in USD (18 decimals)
    /// @dev Zero when the tranche holds no assets, without consulting the oracle.
    /// @return capital The total capital value in USD (18 decimals)
    function totalCapital() external view returns (uint256 capital);

    /// @notice Get the active capital value of the tranche in USD (18 decimals)
    /// @dev Zero when no assets are active, without consulting the oracle.
    /// @return capital The active capital value in USD (18 decimals)
    function activeCapital() external view returns (uint256 capital);
}
