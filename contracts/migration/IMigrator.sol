// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IMigrator
/// @author kexley, Cap Labs
/// @notice Interface for the one-shot migration of the live cUSD and stcUSD proxies onto v2
/// @dev Runbook, in order:
/// 1. At least one `lockDuration` ahead, point the v1 FeeReceiver's `setStakedCapToken` at the
/// migrator so fee proceeds stop vesting into stcUSD and collect there. It answers the
/// {lastNotify} and {lockDuration} calls `distribute` makes, which a plain wallet cannot.
/// 2. Complete the v1 unwind: loans repaid, reserve divested and its interest realized, everything
/// back in USDC on cUSD. The v1 harvest functions live on cUSD and are gone once it is upgraded.
/// v1 priced mints and burns off the oracle, so the USDC it records falls slightly short of the cUSD
/// supply even after a full unwind; the executor approves the migrator for that shortfall.
/// 3. If stcUSD holds an un-notified balance, call its `notify`; wait out any running release.
/// 4. Grant the migrator v1 upgrade access on both proxies.
/// 5. Configure the v2 AccessManager, so the upgrader can upgrade both tokens once they are on v2.
/// 6. The executor calls {migrate} with a cap on the top-up; it refuses to finish unless steps 1
/// to 3 and 5 are done.
/// Recover forward: v2 never updates v1 stcUSD's `storedTotal`, so rolling the proxies back to v1
/// after holders have moved through v2 would let early v1 redeemers be paid from later ones.
interface IMigrator {
    /// @notice Addresses and parameters the migration needs
    /// @param executor The only account that may run {migrate}
    /// @param upgrader The account that must be able to upgrade both tokens once they are on v2
    /// @param stablecoin The live cUSD proxy
    /// @param wrapper The live stcUSD proxy
    /// @param feeReceiver The v1 FeeReceiver proxy
    /// @param stablecoinImplementation The v2 cUSD implementation
    /// @param wrapperImplementation The v2 stcUSD implementation
    /// @param authority The v2 access manager
    /// @param underlying The reserve token cUSD redeems into
    /// @param irm The v2 interest rate model
    /// @param reserveVault The v2 reserve vault, or zero
    /// @param vestingPeriod The cUSD premium vesting time constant in seconds
    struct Config {
        address executor;
        address upgrader;
        address stablecoin;
        address wrapper;
        address feeReceiver;
        address stablecoinImplementation;
        address wrapperImplementation;
        address authority;
        address underlying;
        address irm;
        address reserveVault;
        uint256 vestingPeriod;
    }

    /// @notice The caller is not the executor
    error NotExecutor();

    /// @notice The migration has already run
    error AlreadyMigrated();

    /// @notice The migration has not run yet
    error NotMigrated();

    /// @notice v1 still has an asset lent to agents
    /// @param asset The asset with loans outstanding
    error LoansOutstanding(address asset);

    /// @notice v1 still has an asset invested in its fractional reserve vault
    /// @param asset The asset still invested
    error ReserveInvested(address asset);

    /// @notice v1 has fractional reserve interest that has not been realized
    /// @param asset The asset with unrealized interest
    error InterestUnrealized(address asset);

    /// @notice A token's supply or permit domain changed across the upgrade
    error StateNotCarriedOver();

    /// @notice cUSD does not hold the underlying for its whole supply, so v2 would cap its exits
    error UnwindIncomplete();

    /// @notice A token is not governed by the configured access manager, or the upgrader cannot
    /// upgrade it there
    /// @param proxy The token proxy
    error AccessNotConfigured(address proxy);

    /// @notice Bringing cUSD to par would take more of the underlying than the executor allowed
    /// @param shortfall The underlying needed
    /// @param maxTopUp The most the executor allowed
    error TopUpExceedsMax(uint256 shortfall, uint256 maxTopUp);

    /// @notice v1 stcUSD still has locked or un-notified profit that would enter the v2 price at once
    error StakedPriceWouldJump();

    /// @notice Emitted when both proxies are on v2 and every check has passed
    event Migrated();

    /// @notice Emitted when the executor tops cUSD up to par
    /// @param amount The underlying added
    event ToppedUp(uint256 amount);

    /// @notice Emitted when collected fees are returned to cUSD holders
    /// @param shares The cUSD withdrawn
    /// @param assets The underlying funded back through {IStablecoin-fund}
    event FeesReturned(uint256 shares, uint256 assets);

    /// @notice Get the only account that may run {migrate}
    /// @return account The executor
    function executor() external view returns (address account);

    /// @notice Get the account that must be able to upgrade both tokens once they are on v2
    /// @return account The upgrader
    function upgrader() external view returns (address account);

    /// @notice Get the live cUSD proxy
    /// @return proxy The cUSD proxy
    function stablecoin() external view returns (address proxy);

    /// @notice Get the live stcUSD proxy
    /// @return proxy The stcUSD proxy
    function wrapper() external view returns (address proxy);

    /// @notice Get the v1 FeeReceiver proxy
    /// @return proxy The FeeReceiver proxy
    function feeReceiver() external view returns (address proxy);

    /// @notice Get the v2 cUSD implementation
    /// @return implementation The cUSD implementation
    function stablecoinImplementation() external view returns (address implementation);

    /// @notice Get the v2 stcUSD implementation
    /// @return implementation The stcUSD implementation
    function wrapperImplementation() external view returns (address implementation);

    /// @notice Get the v2 access manager both tokens are initialized with
    /// @return manager The access manager
    function authority() external view returns (address manager);

    /// @notice Get the reserve token cUSD redeems into
    /// @return token The underlying
    function underlying() external view returns (address token);

    /// @notice Get the v2 interest rate model cUSD is initialized with
    /// @return model The interest rate model
    function irm() external view returns (address model);

    /// @notice Get the v2 reserve vault cUSD is initialized with
    /// @return vault The reserve vault, or zero
    function reserveVault() external view returns (address vault);

    /// @notice Get the cUSD premium vesting time constant
    /// @return period The time constant in seconds
    function vestingPeriod() external view returns (uint256 period);

    /// @notice Get whether the migration has run
    /// @return done Whether {migrate} has completed
    function migrated() external view returns (bool done);

    /// @notice Answer the v1 FeeReceiver as its staked token: notified just now
    /// @dev With {lockDuration} at zero, `distribute` never tries to notify the migrator.
    /// @return timestamp The current block timestamp
    function lastNotify() external view returns (uint256 timestamp);

    /// @notice Answer the v1 FeeReceiver as its staked token: no lock
    /// @return duration Zero
    function lockDuration() external pure returns (uint256 duration);

    /// @notice Collect the v1 fees, top cUSD up to par, upgrade cUSD then stcUSD, check the result,
    /// and return the fees to cUSD holders
    /// @dev Executor only, once. The shortfall between the cUSD supply and the underlying cUSD holds
    /// is pulled from the executor. Reverts:
    /// - {LoansOutstanding}, {ReserveInvested} or {InterestUnrealized} while any v1 asset is still
    /// lent, invested or owed interest
    /// - {TopUpExceedsMax} if the shortfall is more than `maxTopUp`
    /// - {StateNotCarriedOver} if a supply or permit domain moved
    /// - {AccessNotConfigured} unless the upgrader can upgrade both tokens through the access manager
    /// - {UnwindIncomplete} unless cUSD can honour every exit
    /// - {StakedPriceWouldJump} if the stcUSD price would rise more than 1 bp
    /// - if the FeeReceiver points anywhere that cannot answer it
    /// @param maxTopUp The most underlying the executor will add to bring cUSD to par
    function migrate(uint256 maxTopUp) external;

    /// @notice Return fees that reach the migrator after {migrate} to cUSD holders
    /// @dev Permissionless: it only ever funds the cUSD vest. Reverts {NotMigrated} before {migrate}.
    function returnFees() external;
}
