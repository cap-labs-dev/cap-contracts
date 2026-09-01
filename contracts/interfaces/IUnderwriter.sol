// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";

/// @title IUnderwriter
/// @author kexley, Cap Labs
/// @notice Interface for the curator vault that allocates vault assets into tranches and distributes premium
interface IUnderwriter is IERC7540AsyncRedeem {
    /// @notice The tranche is not registered with the underwriter
    error NotRegisteredTranche();

    /// @notice The vesting period is zero
    error InvalidVestingPeriod();

    /// @notice Emitted when a tranche is registered with the underwriter
    /// @param tranche The tranche address
    event AddTranche(address indexed tranche);

    /// @notice Emitted when a tranche is removed from the underwriter
    /// @param tranche The tranche address
    event RemoveTranche(address indexed tranche);

    /// @notice Emitted when recorded tranche debt increases
    /// @param tranche The tranche address
    /// @param amount The amount of debt added
    event DebtIncreased(address indexed tranche, uint256 amount);

    /// @notice Emitted when recorded tranche debt decreases
    /// @param tranche The tranche address
    /// @param amount The amount of debt removed
    event DebtDecreased(address indexed tranche, uint256 amount);

    /// @notice Emitted when an async tranche redemption is requested
    /// @param tranche The tranche address
    /// @param shares The shares requested for redemption
    /// @param requestId The ERC-7540 request id
    event RequestedRedeem(address indexed tranche, uint256 shares, uint256 requestId);

    /// @notice Emitted when a tranche is reported
    /// @param tranche The tranche address
    /// @param reward The premium claimed from the tranche
    /// @param gain The increase in recorded tranche debt
    /// @param loss The decrease in recorded tranche debt
    event Reported(address indexed tranche, uint256 reward, uint256 gain, uint256 loss);

    /// @notice Emitted when the default allocation tranche is updated
    /// @param tranche The new default tranche address
    event SetDefaultTranche(address tranche);

    /// @notice Emitted when the premium vesting period is updated
    /// @param vestingPeriod The new vesting period in seconds
    event SetVestingPeriod(uint256 vestingPeriod);

    /// @notice Initialize the underwriter
    /// @param authority The access manager address
    /// @param name The share token name
    /// @param symbol The share token symbol
    /// @param asset The vault asset deposited by curators
    /// @param vaultAddress The vault holding curator assets
    /// @param stablecoinAddress The stablecoin used for premium payments
    function initialize(
        address authority,
        string memory name,
        string memory symbol,
        address asset,
        address vaultAddress,
        address stablecoinAddress
    ) external;

    /// @notice Register a tranche for allocation and reporting
    /// @param tranche The tranche address
    function addTranche(address tranche) external;

    /// @notice Remove a tranche from the underwriter to block new allocations
    /// @param tranche The tranche address
    function removeTranche(address tranche) external;

    /// @notice Allocate vault assets into a registered tranche
    /// @param tranche The tranche address
    /// @param assets The amount of assets to allocate
    function allocate(address tranche, uint256 assets) external;

    /// @notice Instantly redeem unlocked tranche shares back to the vault
    /// @param tranche The tranche address
    /// @param shares The shares to redeem
    /// @return deallocated The amount of shares redeemed
    function deallocate(address tranche, uint256 shares) external returns (uint256 deallocated);

    /// @notice Request async redemption of tranche shares back to the vault
    /// @param tranche The tranche address
    /// @param shares The shares to redeem
    /// @return requestId The ERC-7540 request id
    function deallocateAsync(address tranche, uint256 shares) external returns (uint256 requestId);

    /// @notice Finalize an async tranche redemption
    /// @param tranche The tranche address
    /// @param requestId The ERC-7540 request id
    /// @param shares The shares to redeem
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares) external;

    /// @notice Set the registered tranche that receives deposits by default
    /// @param tranche The default tranche address
    function setDefaultTranche(address tranche) external;

    /// @notice Set the premium vesting period
    /// @param vestingPeriod The new vesting period in seconds
    function setVestingPeriod(uint256 vestingPeriod) external;

    /// @notice Set whether an account may deposit
    /// @param account The account to update
    /// @param allowed Whether the account is whitelisted
    function whitelist(address account, bool allowed) external;

    /// @notice Update recorded tranche debt and claim premium into the underwriter
    /// @param tranche The tranche address
    function report(address tranche) external;

    /// @notice Claim vested premium for the caller
    function claim() external;

    /// @notice Get the vault holding curator assets
    function vault() external view returns (address);

    /// @notice Get the stablecoin used for premium payments
    function stablecoin() external view returns (address);

    /// @notice Get the premium vesting period in seconds
    function vestingPeriod() external view returns (uint256);

    /// @notice Get the timestamp of the last tranche report
    function lastReported() external view returns (uint256);

    /// @notice Get the total premium from the last report that is vesting to depositors
    function vestedPremium() external view returns (uint256);

    /// @notice Get the premium accrual rate per second from the last report
    function premiumPerSecond() external view returns (uint256);

    /// @notice Get the timestamp of the last premium accrual update
    function lastPremiumUpdate() external view returns (uint256);

    /// @notice Get the accumulated premium per share in ray decimals
    function premiumPerShare() external view returns (uint256);

    /// @notice Get pending premium already settled for an account
    /// @param user The account to query
    function pendingPremium(address user) external view returns (uint256);

    /// @notice Get the default allocation tranche
    function defaultTranche() external view returns (address);

    /// @notice Get recorded debt for a tranche
    /// @param tranche The tranche address
    function debt(address tranche) external view returns (uint256);

    /// @notice Get total recorded debt across all tranches
    function totalDebt() external view returns (uint256);

    /// @notice Get claimable premium for an account
    /// @param user The account to query
    /// @return premium The claimable premium
    function claimable(address user) external view returns (uint256 premium);

    /// @notice Get the premium from the last report that has not yet vested
    /// @return vested The remaining unvested premium
    function vestedReward() external view returns (uint256 vested);

    /// @notice Get the timestamp when the current vesting epoch ends
    /// @return end The vesting end timestamp
    function vestingEnd() external view returns (uint256 end);

    /// @notice Check whether an account is whitelisted
    /// @param account The account to check
    /// @return allowed Whether the account is whitelisted
    function whitelisted(address account) external view returns (bool allowed);

    /// @notice Total assets including vault balance and recorded tranche debt
    /// @dev Overrides IERC4626: returns vault ERC6909 balance plus totalDebt
    /// @return assets The total assets
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

    /// @notice Shares available for instant redemption based on vault liquidity
    /// @dev Overrides IERC7540AsyncRedeem unlockedSupply
    /// @return unlocked Shares redeemable against vault-held assets
    function unlockedSupply() external view returns (uint256 unlocked);
}
