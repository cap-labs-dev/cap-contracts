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
    /// @param targetHealth Default target health for new markets in ray decimals
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
    /// @param asset The market asset
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @param marketOwnerRole The market owner role id
    /// @param borrowerRole The borrower role id
    /// @param tranches The deployed tranche addresses in seniority order
    event CreateMarket(
        address market,
        address asset,
        string name,
        address marketOwner,
        address borrower,
        uint64 marketOwnerRole,
        uint64 borrowerRole,
        address[] tranches
    );

    /// @notice An underwriter has been created
    /// @param underwriter The deployed underwriter
    /// @param asset The underwriter asset
    /// @param name The underwriter name
    /// @param symbol The underwriter symbol
    /// @param operator The operator address
    /// @param operatorRole The operator role id
    event CreateUnderwriter(
        address underwriter, address asset, string name, string symbol, address operator, uint64 operatorRole
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

    /// @notice Deploy a floating market with tranches at the given weights
    /// @param asset The market asset
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @param weights Tranche weights in ray decimals, index 0 is most senior
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createMarket(
        address asset,
        string memory name,
        address marketOwner,
        address borrower,
        uint256[] calldata weights
    ) external returns (address market, address[] memory deployedTranches);

    /// @notice Deploy a fixed market with tranches at the given weights
    /// @param asset The market asset
    /// @param name The market name
    /// @param marketOwner The market owner operator address
    /// @param borrower The borrower operator address
    /// @param maximumTermLimit The maximum loan term
    /// @param minimumTermLimit The minimum loan term
    /// @param grace The grace period after expiry for admin extensions
    /// @param weights Tranche weights in ray decimals, index 0 is most senior
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function createFixedMarket(
        address asset,
        string memory name,
        address marketOwner,
        address borrower,
        uint256 maximumTermLimit,
        uint256 minimumTermLimit,
        uint256 grace,
        uint256[] calldata weights
    ) external returns (address market, address[] memory deployedTranches);

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
