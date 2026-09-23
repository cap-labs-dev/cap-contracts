// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IRegistry
/// @author kexley, Cap Labs
/// @notice Interface for deploying and tracking protocol instances
interface IRegistry {
    /// @notice The address is the zero address
    error ZeroAddress();

    /// @notice The operator role is not assigned
    error OperatorNotAssigned();

    /// @notice The role is not a dynamic operator role
    error NotOperatorRole();

    /// @notice The public role cannot perform privileged operations
    error PublicRole();

    /// @notice The tranche count is invalid
    error InvalidTrancheCount();

    /// @notice The assets and weights describe a different number of tranches
    error TrancheAssetsMismatch();

    /// @notice The market was not deployed by this registry
    error UnknownMarket();

    /// @notice The caller does not hold the market's owner role
    error NotMarketOwner();

    /// @notice The requested slice starts after its end
    /// @dev `start` must not exceed `end`. Bounds past the collection are clamped to its length.
    error InvalidRange();

    /// @notice Shared initialization parameters for the registry
    /// @param stablecoin The stablecoin address
    /// @param vault The vault address
    /// @param oracle The oracle address
    /// @param irm The interest rate model address
    /// @param factory The beacon proxy factory address
    /// @param floatingMarketBeacon The floating market beacon address
    /// @param fixedMarketBeacon The fixed market beacon address
    /// @param trancheBeacon The tranche beacon address
    /// @param underwriterBeacon The underwriter beacon address
    /// @param wrapper The staked-stablecoin wrapper address
    struct InitParams {
        address stablecoin;
        address vault;
        address oracle;
        address irm;
        address factory;
        address floatingMarketBeacon;
        address fixedMarketBeacon;
        address trancheBeacon;
        address underwriterBeacon;
        address wrapper;
    }

    /// @notice Emitted when child roles are created with their initial members
    /// @param parentRoleId The role that administers the child roles
    /// @param members The initial members for each corresponding child role
    /// @param roleIds The created child role ids
    event CreateChildRoles(uint64 indexed parentRoleId, address[][] members, uint64[] roleIds);

    /// @notice Emitted when a market is created
    /// @param market The deployed market
    /// @param assets The asset of each tranche, in the same order as `tranches`
    /// @param name The market name
    /// @param marketOwnerRole The market owner role id
    /// @param tranches The deployed tranche addresses in seniority order
    event CreateMarket(address market, address[] assets, string name, uint64 marketOwnerRole, address[] tranches);

    /// @notice Emitted when a tranche is deployed for a market
    /// @param market The market the tranche was deployed for
    /// @param tranche The deployed tranche
    /// @param asset The tranche asset
    /// @param marketOwnerRole The owner role the tranche was wired to
    /// @param depositorRole The role that may deposit, administered by the market owner
    event CreateTranche(
        address indexed market, address tranche, address asset, uint64 marketOwnerRole, uint64 depositorRole
    );

    /// @notice Emitted when an underwriter is created
    /// @param underwriter The deployed underwriter
    /// @param asset The underwriter asset
    /// @param name The underwriter name
    /// @param symbol The underwriter symbol
    /// @param curatorRole The curator role id
    event CreateUnderwriter(address underwriter, address asset, string name, string symbol, uint64 curatorRole);

    /// @notice Emitted when the depositor role is updated
    /// @param target The market, tranche, or underwriter whose depositor role changed
    /// @param roleId The new depositor role id
    event SetDepositorRole(address indexed target, uint64 indexed roleId);

    /// @notice Emitted when the borrower role is updated
    /// @param market The market whose borrower role changed
    /// @param roleId The new borrower role id
    event SetBorrowerRole(address indexed market, uint64 indexed roleId);

    /// @notice Emitted when the allocator role is updated
    /// @param underwriter The underwriter whose allocator role changed
    /// @param roleId The new allocator role id
    event SetAllocatorRole(address indexed underwriter, uint64 indexed roleId);

    /// @notice Initialize the registry and wire shared infrastructure roles
    /// @dev This contract must hold ADMIN to call `setTargetFunctionRole`. Per-market roles are
    /// wired on create. Every UUPS `upgradeToAndCall` is named as ADMIN here so it cannot sit
    /// at ADMIN only by omission.
    /// @param authority The access manager address
    /// @param init The registry initialization parameters
    function initialize(address authority, InitParams calldata init) external;

    /// @notice Create child roles and seed their initial members in one transaction
    /// @dev Restricted to WHITELISTED so users can create operator groups.
    /// @param parentRoleId The role that will administer every new child role
    /// @param members The initial members for each corresponding child role
    /// @return roleIds The created child role ids
    function createChildRoles(uint64 parentRoleId, address[][] calldata members)
        external
        returns (uint64[] memory roleIds);

    /// @notice Get whether a role id was created as an operator role
    /// @param roleId The role id to query
    /// @return assigned Whether the role is an operator role
    function isOperatorRole(uint64 roleId) external view returns (bool assigned);

    /// @notice Deploy a floating market with tranches at the given assets and weights
    /// @dev Restricted to WHITELISTED. One tranche per entry of `assets` and `weights`.
    /// Between one and ten tranches may be created; the limit is checked before deployment.
    /// Borrow, borrowMore and extend start on a closed role the owner administers, so they
    /// cannot sit at ADMIN until {setBorrowerRole}.
    /// Tranches use the default premium vesting period of 12 hours.
    /// @param assets The asset of each tranche, index 0 is most senior
    /// @param weights The tranche weights in ray decimals, index 0 is most senior
    /// @param name The market name
    /// @param marketOwnerRole The market owner operator role id
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createFloatingMarket(
        address[] calldata assets,
        uint256[] calldata weights,
        string memory name,
        uint64 marketOwnerRole
    ) external returns (address market, address[] memory deployedTranches);

    /// @notice Deploy a fixed market with tranches at the given assets and weights
    /// @dev Restricted to WHITELISTED. See {createFloatingMarket} for tranche inputs.
    /// Tranches start with a premium vesting period of `maximumTermLimit / 2`, rounded down.
    /// The resulting period must be nonzero and no greater than one ray seconds.
    /// Later term-limit changes do not change existing tranche vesting periods.
    /// @param assets The asset of each tranche, index 0 is most senior
    /// @param weights The tranche weights in ray decimals, index 0 is most senior
    /// @param name The market name
    /// @param marketOwnerRole The market owner operator role id
    /// @param maximumTermLimit The maximum loan term
    /// @param minimumTermLimit The minimum loan term
    /// @param grace The grace period after expiry for admin extensions
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createFixedMarket(
        address[] calldata assets,
        uint256[] calldata weights,
        string memory name,
        uint64 marketOwnerRole,
        uint256 maximumTermLimit,
        uint256 minimumTermLimit,
        uint256 grace
    ) external returns (address market, address[] memory deployedTranches);

    /// @notice Add a junior tranche to a market and reweight the waterfall
    /// @dev Caller must hold the market owner role. `weights` covers the whole waterfall, including the new junior.
    /// Reverts before deployment if the market already has ten configured tranches.
    /// The owner supplies the initial premium vesting period; subsequent changes require the governor.
    /// @param market The market to deploy a tranche for
    /// @param asset The asset for the new tranche
    /// @param weights The resulting waterfall weights in ray decimals, last entry is the new tranche
    /// @param vestingPeriod The initial premium vesting time constant in seconds, from 1 through 1e27
    /// @return tranche The deployed tranche
    function createTranche(address market, address asset, uint256[] calldata weights, uint256 vestingPeriod)
        external
        returns (address tranche);

    /// @notice Set the depositor role on the calling tranche or underwriter
    /// @dev Restricted to PROTOCOL. Deployed tranches and underwriters hold that
    /// role so their own owner/curator setters can forward here.
    /// @param roleId The depositor role id
    function setDepositorRole(uint64 roleId) external;

    /// @notice Set the borrower role on the calling market
    /// @dev Restricted to PROTOCOL. Deployed markets hold that role so {IBaseMarket-setBorrowerRole}
    /// can forward here. Replaces the closed borrower role assigned at create.
    /// @param roleId The borrower role id
    function setBorrowerRole(uint64 roleId) external;

    /// @notice Set the allocator role on the calling underwriter
    /// @dev Restricted to PROTOCOL. Deployed underwriters hold that role so
    /// {IUnderwriter-setAllocatorRole} can forward here. Replaces the closed allocator role
    /// assigned at create.
    /// @param roleId The allocator role id
    function setAllocatorRole(uint64 roleId) external;

    /// @notice Get whether this registry deployed the market
    /// @param market The market to query
    /// @return deployed Whether this registry deployed the market
    function isMarket(address market) external view returns (bool deployed);

    /// @notice Get whether this registry deployed the tranche
    /// @param tranche The tranche to query
    /// @return deployed Whether this registry deployed the tranche
    function isTranche(address tranche) external view returns (bool deployed);

    /// @notice Get whether this registry deployed the underwriter
    /// @param underwriter The underwriter to query
    /// @return deployed Whether this registry deployed the underwriter
    function isUnderwriter(address underwriter) external view returns (bool deployed);

    /// @notice Get the number of markets this registry deployed
    /// @return count The market count
    function marketsLength() external view returns (uint256 count);

    /// @notice Get a slice of deployed markets
    /// @dev `end` is exclusive and clamped to the length. A start at or beyond the length returns an empty list.
    /// Inverted ranges revert. `markets(0, type(uint256).max)` returns the full list.
    /// @param start The first index, inclusive
    /// @param end The last index, exclusive
    /// @return listed The markets in that range
    function markets(uint256 start, uint256 end) external view returns (address[] memory listed);

    /// @notice Get the number of tranches this registry deployed
    /// @return count The tranche count
    function tranchesLength() external view returns (uint256 count);

    /// @notice Get a slice of deployed tranches
    /// @dev `end` is exclusive and clamped to the length. A start at or beyond the length returns an empty list.
    /// Inverted ranges revert. `tranches(0, type(uint256).max)` returns the full list.
    /// @param start The first index, inclusive
    /// @param end The last index, exclusive
    /// @return listed The tranches in that range
    function tranches(uint256 start, uint256 end) external view returns (address[] memory listed);

    /// @notice Get the number of underwriters this registry deployed
    /// @return count The underwriter count
    function underwritersLength() external view returns (uint256 count);

    /// @notice Get a slice of deployed underwriters
    /// @dev `end` is exclusive and clamped to the length. A start at or beyond the length returns an empty list.
    /// Inverted ranges revert. `underwriters(0, type(uint256).max)` returns the full list.
    /// @param start The first index, inclusive
    /// @param end The last index, exclusive
    /// @return listed The underwriters in that range
    function underwriters(uint256 start, uint256 end) external view returns (address[] memory listed);

    /// @notice Get the owner role for a market this registry deployed
    /// @dev From {IBaseMarket-setTrancheWeights}. Zero if unknown.
    /// @param market The market to query
    /// @return roleId The market owner role id, or zero if the market is unknown
    function marketOwnerRole(address market) external view returns (uint64 roleId);

    /// @notice Deploy an underwriter for an asset
    /// @dev Restricted to WHITELISTED. Allocate, deallocate, the default route, and deposit
    /// start on closed roles the curator administers, so they cannot sit at ADMIN until
    /// {setAllocatorRole} / {setDepositorRole}.
    /// @param asset The underwriter asset
    /// @param name The underwriter name
    /// @param symbol The underwriter symbol
    /// @param curatorRole The curator operator role id
    /// @return underwriter The deployed underwriter
    function createUnderwriter(address asset, string memory name, string memory symbol, uint64 curatorRole)
        external
        returns (address underwriter);

    /// @notice Get the interest rate model address
    /// @return The interest rate model address
    function irm() external view returns (address);

    /// @notice Get the stablecoin address
    /// @return The stablecoin address
    function stablecoin() external view returns (address);

    /// @notice Get the vault address
    /// @return The vault address
    function vault() external view returns (address);

    /// @notice Get the oracle address
    /// @return The oracle address
    function oracle() external view returns (address);

    /// @notice Get the shared beacon proxy factory address
    /// @return The factory address
    function factory() external view returns (address);

    /// @notice Get the floating market upgradeable beacon address
    /// @return The floating market beacon
    function floatingMarketBeacon() external view returns (address);

    /// @notice Get the fixed market upgradeable beacon address
    /// @return The fixed market beacon
    function fixedMarketBeacon() external view returns (address);

    /// @notice Get the tranche upgradeable beacon address
    /// @return The tranche beacon
    function trancheBeacon() external view returns (address);

    /// @notice Get the underwriter upgradeable beacon address
    /// @return The underwriter beacon
    function underwriterBeacon() external view returns (address);

    /// @notice Get the staked-stablecoin wrapper address
    /// @return The wrapper address
    function wrapper() external view returns (address);
}
