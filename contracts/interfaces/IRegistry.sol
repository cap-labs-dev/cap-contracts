// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IRegistry
/// @author kexley, Cap Labs
/// @notice Interface for deploying and tracking protocol instances
interface IRegistry {
    /// @notice The address is the zero address
    error ZeroAddress();

    /// @notice The operator role is already assigned
    error AlreadyAssigned();

    /// @notice The operator role is not assigned
    error OperatorNotAssigned();

    /// @notice The tranche count is invalid
    error InvalidTrancheCount();

    /// @notice The assets and weights describe a different number of tranches
    error TrancheAssetsMismatch();

    /// @notice The oracle has no price for a tranche asset
    /// @param asset The asset the oracle could not price
    error AssetNotPriced(address asset);

    /// @notice The market was not deployed by this registry
    error UnknownMarket();

    /// @notice Shared initialization parameters for the registry
    /// @param stablecoin The stablecoin address
    /// @param stakedStablecoin The staked stablecoin address
    /// @param vault The vault address
    /// @param oracle The oracle address
    /// @param irm The interest rate model address
    /// @param factory The beacon proxy factory address
    /// @param floatingMarketBeacon The floating market beacon address
    /// @param fixedMarketBeacon The fixed market beacon address
    /// @param trancheBeacon The tranche beacon address
    /// @param underwriterBeacon The underwriter beacon address
    /// @param lt Default liquidation threshold for new markets in ray decimals
    /// @param buffer Default liquidation buffer for new markets in ray decimals
    /// @param targetHealth Default target health for new markets in ray decimals (min 1.25e27)
    struct InitParams {
        address stablecoin;
        address stakedStablecoin;
        address vault;
        address oracle;
        address irm;
        address factory;
        address floatingMarketBeacon;
        address fixedMarketBeacon;
        address trancheBeacon;
        address underwriterBeacon;
        uint256 lt;
        uint256 buffer;
        uint256 targetHealth;
    }

    /// @notice An operator role has been assigned
    /// @param account The account assigned the role
    /// @param roleId The assigned role id
    event OperatorAssigned(address indexed account, uint64 roleId);

    /// @notice A market has been created
    /// @param market The deployed market
    /// @param assets The asset of each tranche, in the same order as `tranches`
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @param marketOwnerRole The market owner role id
    /// @param borrowerRole The borrower role id
    /// @param tranches The deployed tranche addresses in seniority order
    event CreateMarket(
        address market,
        address[] assets,
        string name,
        address marketOwner,
        address borrower,
        uint64 marketOwnerRole,
        uint64 borrowerRole,
        address[] tranches
    );

    /// @notice A tranche has been deployed for a market
    /// @dev Emitted for every tranche, both the ones a market is created with and the ones added
    /// to it later, so the depositor role of each one is observable from a single event
    /// @param market The market the tranche was deployed for
    /// @param tranche The deployed tranche
    /// @param asset The tranche asset
    /// @param marketOwnerRole The market owner role id the tranche was wired to
    /// @param depositorRole The role whose members may deposit, administered by the market owner
    /// role
    event CreateTranche(
        address indexed market, address tranche, address asset, uint64 marketOwnerRole, uint64 depositorRole
    );

    /// @notice An underwriter has been created
    /// @param underwriter The deployed underwriter
    /// @param asset The underwriter asset
    /// @param name The underwriter name
    /// @param symbol The underwriter symbol
    /// @param operator The operator address
    /// @param operatorRole The operator role id
    /// @param depositorRole The role whose members may deposit, administered by the operator role
    event CreateUnderwriter(
        address underwriter,
        address asset,
        string name,
        string symbol,
        address operator,
        uint64 operatorRole,
        uint64 depositorRole
    );

    /// @notice Initialize the registry
    /// @param authority The access manager address
    /// @param init The registry initialization parameters
    function initialize(address authority, InitParams calldata init) external;

    /// @notice Assign the next operator role id to an account (GOVERNOR)
    /// @param account The account to assign
    /// @return roleId The assigned role id
    function assignOperator(address account) external returns (uint64 roleId);

    /// @notice Get the operator role id for an account
    /// @param account The account to query
    /// @return roleId The operator role id, or zero if unassigned
    function operatorRole(address account) external view returns (uint64 roleId);

    /// @notice Deploy a floating market with tranches at the given assets and weights
    /// @dev One tranche is deployed per entry, so `assets` and `weights` must be the same length.
    /// The assets may differ from each other: the market never touches a collateral token, it
    /// values every tranche in USD through {ITranche-totalCapital}, so a waterfall can be built
    /// out of whatever mix of collateral the oracle can price.
    /// @param assets The asset of each tranche, index 0 is most senior
    /// @param weights Tranche weights in ray decimals, index 0 is most senior
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createMarket(
        address[] calldata assets,
        uint256[] calldata weights,
        string memory name,
        address marketOwner,
        address borrower
    ) external returns (address market, address[] memory deployedTranches);

    /// @notice Deploy a fixed market with tranches at the given assets and weights
    /// @dev See {createMarket} for how `assets` and `weights` pair up
    /// @param assets The asset of each tranche, index 0 is most senior
    /// @param weights Tranche weights in ray decimals, index 0 is most senior
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @param maximumTermLimit The maximum loan term
    /// @param minimumTermLimit The minimum loan term
    /// @param grace The grace period after expiry for admin extensions
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createFixedMarket(
        address[] calldata assets,
        uint256[] calldata weights,
        string memory name,
        address marketOwner,
        address borrower,
        uint256 maximumTermLimit,
        uint256 minimumTermLimit,
        uint256 grace
    ) external returns (address market, address[] memory deployedTranches);

    /// @notice Add a tranche to a market this registry already created and reweight the waterfall
    /// @dev The tranche joins as the most junior position, so `weights` must be one entry longer
    /// than the market's current list and is applied to the whole waterfall in one go. Ordering
    /// and removals are left to {IBaseMarket-setTranches}: to retire a tranche, add its
    /// replacement here and then call that with the list you want. The owner role is taken from
    /// the market rather than from an argument, so a new tranche cannot be wired to somebody
    /// else's operator role. It opens with an empty depositor role, reported by {CreateTranche},
    /// which the market owner fills through the AccessManager.
    ///
    /// This is ADMIN rather than KEEPER because it ends in a {IBaseMarket-setTranches} call. That
    /// still enforces the weight total and market health, but choosing who backs a market's debt
    /// is not routine deployment work.
    /// @param market The market to deploy a tranche for
    /// @param asset The asset for the new tranche, which need not match the existing tranches
    /// @param weights Tranche weights in ray decimals for the resulting waterfall, index 0 is most
    /// senior and the last entry is the new tranche
    /// @return tranche The deployed tranche
    function createTranche(address market, address asset, uint256[] calldata weights) external returns (address tranche);

    /// @notice Get whether a market was deployed by this registry
    /// @dev The record {createTranche} checks. Kept as a flag rather than as a copy of the market
    /// owner role, so that nothing here can disagree with the AccessManager about who the owner
    /// is; see {marketOwnerRole}.
    /// @param market The market to query
    /// @return deployed Whether this registry deployed the market
    function isMarket(address market) external view returns (bool deployed);

    /// @notice Get the market owner role id for a market deployed by this registry
    /// @dev Read live from the AccessManager off the role wired to
    /// {IBaseMarket-setTrancheWeights}, so repointing a market's owner selectors moves the owner
    /// this reports. Zero for a market this registry did not deploy, which is also the id of
    /// ADMIN, so callers wanting to tell those apart should ask {isMarket}.
    /// @param market The market to query
    /// @return roleId The market owner role id, or zero if the market is unknown
    function marketOwnerRole(address market) external view returns (uint64 roleId);

    /// @notice Deploy an underwriter for an asset
    /// @param asset The underwriter asset
    /// @param name The underwriter name
    /// @param symbol The underwriter symbol
    /// @param operator The operator address
    /// @return underwriter The deployed underwriter
    function createUnderwriter(address asset, string memory name, string memory symbol, address operator)
        external
        returns (address underwriter);

    /// @notice Get the interest rate model address
    function irm() external view returns (address);

    /// @notice Get the stablecoin address
    function stablecoin() external view returns (address);

    /// @notice Get the staked stablecoin address
    function stakedStablecoin() external view returns (address);

    /// @notice Get the vault address
    function vault() external view returns (address);

    /// @notice Get the oracle address
    function oracle() external view returns (address);

    /// @notice Get the shared beacon proxy factory address
    function factory() external view returns (address);

    /// @notice Get the floating market upgradeable beacon address
    function floatingMarketBeacon() external view returns (address);

    /// @notice Get the fixed market upgradeable beacon address
    function fixedMarketBeacon() external view returns (address);

    /// @notice Get the tranche upgradeable beacon address
    function trancheBeacon() external view returns (address);

    /// @notice Get the underwriter upgradeable beacon address
    function underwriterBeacon() external view returns (address);

    /// @notice Default liquidation threshold for new markets in ray decimals
    function lt() external view returns (uint256);

    /// @notice Default liquidation buffer for new markets in ray decimals
    function buffer() external view returns (uint256);

    /// @notice Default target health for new markets in ray decimals
    function targetHealth() external view returns (uint256);
}
