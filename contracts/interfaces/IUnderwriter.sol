// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";

/// @title IUnderwriter
/// @author kexley, Cap Labs
/// @notice Interface for the curator vault that allocates vault assets into tranches and distributes premium
/// @dev The curator role is expected to be held by a timelock or secure multisig, while the
/// allocator role is intended for an operational wallet with narrower permissions. Beacon instance:
/// upgrade via {UpgradeableBeacon-upgradeTo} on the underwriter beacon.
interface IUnderwriter is IERC7540AsyncRedeem {
    /// @notice The tranche is not registered with the underwriter
    error NotRegisteredTranche();

    /// @notice The named shares exceed this vault's queue under that request id
    error UnknownQueuedRequest();

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
    /// @param reward The premium claimed from the tranche, in stablecoin units (18 decimals)
    /// @param gain The increase in recorded tranche debt
    /// @param loss The decrease in recorded tranche debt
    event Reported(address indexed tranche, uint256 reward, uint256 gain, uint256 loss);

    /// @notice Emitted when the default allocation tranche is updated
    /// @param tranche The new default tranche address
    event SetDefaultTranche(address tranche);

    /// @notice Initialize the underwriter
    /// @param authority The access manager address
    /// @param registryAddress The registry that configures access roles
    /// @param name The share token name
    /// @param symbol The share token symbol
    /// @param asset The vault asset deposited by curators
    /// @param vaultAddress The vault holding curator assets
    /// @param stablecoinAddress The stablecoin used for premium payments
    /// @param vestingPeriod The initial premium vesting time constant in seconds
    function initialize(
        address authority,
        address registryAddress,
        string memory name,
        string memory symbol,
        address asset,
        address vaultAddress,
        address stablecoinAddress,
        uint256 vestingPeriod
    ) external;

    /// @notice Set the role permitted to deposit
    /// @param roleId The depositor role id
    function setDepositorRole(uint64 roleId) external;

    /// @notice Set the role permitted to allocate and deallocate
    /// @param roleId The allocator role id
    function setAllocatorRole(uint64 roleId) external;

    /// @notice Register a tranche for allocation
    /// @dev Curator only. The curator is trusted to name a real protocol tranche for this vault
    /// and asset. Grants the tranche vault operator rights until {removeTranche}.
    /// @param tranche The tranche address
    function addTranche(address tranche) external;

    /// @notice Remove a tranche and block new allocations
    /// @dev Curator only. Revokes vault operator rights. Existing shares can still be redeemed,
    /// and {report} can still claim later premium on that leftover position.
    /// @param tranche The tranche address
    function removeTranche(address tranche) external;

    /// @notice Allocate vault assets into a registered tranche
    /// @dev Allocator only.
    /// @param tranche The tranche address
    /// @param assets The amount of assets to allocate
    function allocate(address tranche, uint256 assets) external;

    /// @notice Instantly redeem unlocked tranche shares back to the vault
    /// @dev Allocator only. Tranches can be removed from registration and still deallocated.
    /// Remakes the mark only if {debt} is already nonzero — an airdrop cannot open a book.
    /// @param tranche The tranche address
    /// @param shares The shares to redeem
    /// @return deallocated The amount of shares redeemed
    function deallocate(address tranche, uint256 shares) external returns (uint256 deallocated);

    /// @notice Request async redemption of tranche shares back to the vault
    /// @dev Allocator only. Registration is not checked; see {deallocate}.
    /// @param tranche The tranche address
    /// @param shares The shares to redeem
    /// @return requestId The ERC-7540 request id
    function deallocateAsync(address tranche, uint256 shares) external returns (uint256 requestId);

    /// @notice Finalize an async tranche redemption
    /// @dev Allocator only. Registration is not checked; see {deallocate}.
    /// @param tranche The tranche address
    /// @param requestId The ERC-7540 request id
    /// @param shares The shares to redeem
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares) external;

    /// @notice Set the registered tranche that receives deposits by default
    /// @dev Allocator only.
    /// @param tranche The default tranche address
    function setDefaultTranche(address tranche) external;

    /// @notice Re-value a tranche position and claim its premium
    /// @dev Registration is not checked; see {deallocate}. Remakes the mark only if {allocate}
    /// already opened one. Valuations stay cached between marks. Deposit and mint quotes
    /// separately value the default position at its current value.
    /// Harvested premium enters the pool's own vesting pot, whose period the curator controls.
    /// It rewards opted-in balances as it vests, including holders who joined after the tranche
    /// generated it. Previously credited pool rewards remain with their original holders.
    /// @param tranche The tranche address
    function report(address tranche) external;

    /// @notice Get the vault holding curator assets
    /// @return The vault address
    function vault() external view returns (address);

    /// @notice Get the registry that configures access roles
    /// @return The registry address
    function registry() external view returns (address);

    /// @notice Get when {report} last folded premium into the remainder
    /// @return The last report timestamp
    function lastReported() external view returns (uint256);

    /// @notice Get the default allocation tranche
    /// @return The default tranche address
    function defaultTranche() external view returns (address);

    /// @notice Get the shares queued for redemption but not yet settled
    /// @dev Still counted in {debt}.
    /// @param tranche The tranche address
    /// @return The queued share count
    function queuedShares(address tranche) external view returns (uint256);

    /// @notice Get the shares queued under one {deallocateAsync} request
    /// @param tranche The tranche address
    /// @param requestId The ERC-7540 request id
    /// @return The shares queued under that request
    function queuedRequest(address tranche, uint256 requestId) external view returns (uint256);

    /// @notice Get the recorded value of this vault's position in a tranche
    /// @param tranche The tranche address
    /// @return The recorded position value
    function debt(address tranche) external view returns (uint256);

    /// @notice Get the sum of every {debt} entry
    /// @return The sum of every recorded position
    function totalDebt() external view returns (uint256);

    /// @notice Get the total assets including vault balance and recorded tranche debt
    /// @dev Vault ERC6909 balance plus {totalDebt}. A slash is folded in only when {allocate}
    /// opens or remakes the book, or when {report} / {deallocate} remake a book that already
    /// exists. Deposit and mint quotes separately adjust for the default position, including
    /// queued shares and positions whose recorded debt is zero, without writing the book.
    /// Non-default positions remain cached, so unreported gains and losses also affect issuance pricing.
    /// @return assets The total assets
    function totalAssets() external view returns (uint256 assets);

    /// @notice Get the shares available for instant redemption based on vault liquidity
    /// @return unlocked The shares redeemable against vault-held assets
    function unlockedSupply() external view returns (uint256 unlocked);
}
