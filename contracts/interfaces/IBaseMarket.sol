// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IBaseMarket
/// @author kexley, Cap Labs
/// @notice Shared interface for fixed and floating market implementations
/// @dev Beacon instances. Upgrade via {UpgradeableBeacon-upgradeTo} on the market beacon.
interface IBaseMarket {
    /// @notice A struct representing a tranche
    /// @param tranche The tranche address
    /// @param weight The tranche weight in ray decimals
    struct Tranche {
        address tranche;
        uint256 weight;
    }

    /// @custom:storage-location cap.storage.BaseMarket
    /// @param name The market name
    /// @param stablecoin The stablecoin address
    /// @param irm The interest rate model address
    /// @param targetHealth The target health in ray decimals
    /// @param loanToValue The loan-to-value ratio in ray decimals
    /// @param buffer The liquidation buffer in ray decimals
    /// @param liquidationThreshold The liquidation threshold in ray decimals
    /// @param tranches The tranches and their weights
    /// @param registry The registry that deployed and configures the market
    /// @param marketMultiplier The liquidity-rate multiplier in ray decimals. Zero reads as one ray.
    struct BaseMarketStorage {
        string name;
        address registry;
        address stablecoin;
        address irm;
        uint256 targetHealth;
        uint256 loanToValue;
        uint256 buffer;
        uint256 liquidationThreshold;
        Tranche[] tranches;
        uint256 marketMultiplier;
    }

    /// @notice The loan-to-value ratio exceeds the liquidation threshold minus buffer
    error InvalidLoanToValue();

    /// @notice The buffer is below 10% or is not strictly below the liquidation threshold
    error InvalidBuffer();

    /// @notice The liquidation threshold exceeds the maximum allowed value
    error InvalidLiquidationThreshold();

    /// @notice The target health is below the minimum allowed value
    error InvalidTargetHealth();

    /// @notice The market or tranche configuration is invalid
    error InvalidMarket();

    /// @notice The address is the zero address
    error ZeroAddress();

    /// @notice The market is healthy and cannot be liquidated
    error Healthy();

    /// @notice The market has become unhealthy
    error Unhealthy();

    /// @notice The principal amount is zero
    error InvalidPrincipal();

    /// @notice The amount is invalid
    error InvalidAmount();

    /// @notice The market has insufficient liquidity for the requested borrow
    error InsufficientLiquidity();

    /// @notice The tranche weights do not sum to one ray
    error InvalidTrancheWeightsTotal();

    /// @notice The tranche is already set
    error TrancheAlreadySet();

    /// @notice The market would exceed the fixed limit of ten configured tranches
    error TooManyTranches();

    /// @notice The write off exceeds the debt that liquidation could never recover
    error ExceedsUnrecoverableDebt();

    /// @notice Emitted when assets are borrowed from the market
    /// @param recipient The address receiving the borrowed assets
    /// @param principal The amount borrowed, in stablecoin units (18 decimals)
    event Borrow(address recipient, uint256 principal);

    /// @notice Emitted when debt is repaid to the market
    /// @param caller The address repaying the debt
    /// @param amount The amount repaid, in stablecoin units (18 decimals)
    event Repay(address caller, uint256 amount);

    /// @notice Emitted when an unhealthy position is liquidated
    /// @param caller The address initiating the liquidation
    /// @param recipient The address receiving slashed collateral
    /// @param repaid The amount of debt repaid, in stablecoin units (18 decimals)
    /// @param valueSlashed The USD value of collateral delivered, 18 decimals, possibly across tokens
    event Liquidate(address caller, address recipient, uint256 repaid, uint256 valueSlashed);

    /// @notice Emitted when unrecoverable debt is written off the market
    /// @param caller The address initiating the write off
    /// @param amount The amount of debt written off, in stablecoin units (18 decimals)
    /// @param remainingDebt The market's debt after the write off, in stablecoin units (18 decimals)
    event WriteOff(address indexed caller, uint256 amount, uint256 remainingDebt);

    /// @notice Emitted when the loan-to-value ratio is updated
    /// @param loanToValue The new loan-to-value ratio in ray decimals
    event SetLoanToValue(uint256 loanToValue);

    /// @notice Emitted when the liquidation buffer is updated
    /// @param buffer The new buffer in ray decimals
    event SetBuffer(uint256 buffer);

    /// @notice Emitted when the liquidation threshold is updated
    /// @param liquidationThreshold The new liquidation threshold in ray decimals
    event SetLiquidationThreshold(uint256 liquidationThreshold);

    /// @notice Emitted when the target health is updated
    /// @param targetHealth The new target health in ray decimals
    event SetTargetHealth(uint256 targetHealth);

    /// @notice Emitted when the tranches and their weights are updated
    /// @param tranche The tranche address
    /// @param weight The tranche weight in ray decimals
    /// @param index The index of the tranche in the tranches array
    event SetTranche(address indexed tranche, uint256 weight, uint256 index);

    /// @notice Emitted when the underwriter rate is updated
    /// @param rate The new underwriter rate per year in ray decimals
    event SetUnderwriterRate(uint256 rate);

    /// @notice Emitted when the market multiplier is updated
    /// @param multiplier The new market multiplier in ray decimals
    event SetMarketMultiplier(uint256 multiplier);

    /// @notice Emitted when premium is charged to a recipient
    /// @param recipient The recipient of the premium
    /// @param premium The amount of premium minted, in stablecoin units (18 decimals)
    event ChargePremium(address indexed recipient, uint256 premium);

    /// @notice Set the loan-to-value ratio
    /// @param loanToValue The new loan-to-value ratio in ray decimals
    function setLoanToValue(uint256 loanToValue) external;

    /// @notice Set the liquidation buffer
    /// @dev Must be at least 0.1e27 and strictly below {liquidationThreshold}. Credit capacity uses
    /// `min(loanToValue, liquidationThreshold - buffer)`, so raising the buffer can tighten an existing LTV setting.
    /// @param buffer The new buffer in ray decimals
    function setBuffer(uint256 buffer) external;

    /// @notice Set the liquidation threshold
    /// @param liquidationThreshold The new liquidation threshold in ray decimals
    function setLiquidationThreshold(uint256 liquidationThreshold) external;

    /// @notice Set the target health
    /// @param targetHealth The new target health in ray decimals
    function setTargetHealth(uint256 targetHealth) external;

    /// @notice Set the role permitted to borrow from the market
    /// @param roleId The borrower role id
    function setBorrowerRole(uint64 roleId) external;

    /// @notice Set the tranches and their weights
    /// @dev Restricted to the registry; market owners may only change weights.
    /// At most ten tranches may be configured, including empty, killed and zero-weight tranches.
    /// The count is checked before settling premium.
    /// Floating settles outstanding premium under the current list first, so an
    /// already-elapsed period is not reallocated.
    /// @param tranches The new tranche addresses and weights, with weights in ray decimals
    function setTranches(Tranche[] calldata tranches) external;

    /// @notice Set the tranche weights
    /// @dev Floating settles outstanding premium under the current weights first.
    /// @param weights The new tranche weights in ray decimals
    function setTrancheWeights(uint256[] calldata weights) external;

    /// @notice Set the underwriter rate
    /// @param rate The new underwriter rate per year in ray decimals
    function setUnderwriterRate(uint256 rate) external;

    /// @notice Set the market multiplier
    /// @dev Bounded by the IRM min/max. Floating accrues first so the new factor applies only
    /// going forward; fixed applies it to the next term's liquidity rate. Outstanding principal
    /// does not jump.
    /// @param multiplier The new market multiplier in ray decimals
    function setMarketMultiplier(uint256 multiplier) external;

    /// @notice Get the market name
    /// @return The market name
    function name() external view returns (string memory);

    /// @notice Get the stablecoin address
    /// @return The stablecoin address
    function stablecoin() external view returns (address);

    /// @notice Get the interest rate model address
    /// @return The interest rate model address
    function irm() external view returns (address);

    /// @notice Get the registry that deployed the market
    /// @return The registry address
    function registry() external view returns (address);

    /// @notice Get the liquidation threshold in ray decimals
    /// @return The liquidation threshold in ray decimals
    function liquidationThreshold() external view returns (uint256);

    /// @notice Get the liquidation buffer in ray decimals
    /// @return The liquidation buffer in ray decimals
    function buffer() external view returns (uint256);

    /// @notice Get the target health in ray decimals
    /// @return The target health in ray decimals
    function targetHealth() external view returns (uint256);

    /// @notice Get the loan-to-value ratio in ray decimals
    /// @return The loan-to-value ratio in ray decimals
    function loanToValue() external view returns (uint256);

    /// @notice Get the liquidity-rate multiplier in ray decimals
    /// @dev Unset reads as one ray.
    /// @return The market multiplier in ray decimals
    function marketMultiplier() external view returns (uint256);

    /// @notice Get the tranche addresses and weights
    /// @return tranches The tranches and their weights, with weights in ray decimals
    function tranches() external view returns (Tranche[] memory tranches);

    /// @notice Get the total debt of the market
    /// @return debt The total outstanding debt, in stablecoin units (18 decimals)
    function totalDebt() external view returns (uint256 debt);

    /// @notice Get the debt level at which the market hits its liquidation threshold
    /// @return threshold The liquidation threshold expressed as debt capacity, in USD (18 decimals)
    function debtLiquidationThreshold() external view returns (uint256 threshold);

    /// @notice Get the healthiness of the market
    /// @dev Rounded down so debt above {debtLiquidationThreshold} is always unhealthy. Returns
    /// one ray when no debt is outstanding.
    /// @return health The healthiness in ray decimals
    function healthiness() external view returns (uint256 health);

    /// @notice Get the utilization of the market
    /// @return utilization The utilization in ray decimals
    function utilization() external view returns (uint256 utilization);

    /// @notice Get the maximum liquidatable debt
    /// @dev Uses one capital valuation to target {targetHealth}, capped at {recoverableDebt}.
    /// @return liquidatable The maximum liquidatable debt, in stablecoin units (18 decimals)
    function maxLiquidatable() external view returns (uint256 liquidatable);

    /// @notice Get the debt that fully liquidating every tranche could still repay
    /// @dev Collateral clears at `1 + liquidationBonus` per unit of debt.
    /// @return recoverable The recoverable debt, in stablecoin units (18 decimals)
    function recoverableDebt() external view returns (uint256 recoverable);

    /// @notice Get the debt no liquidation can repay
    /// @dev `totalDebt - recoverableDebt`. Tranches need not be empty.
    /// @return unrecoverable The unrecoverable debt, in stablecoin units (18 decimals)
    function unrecoverableDebt() external view returns (uint256 unrecoverable);

    /// @notice Get the capital a tranche must keep locked to back the market's debt
    /// @dev USD, 18 decimals, rounded up. Juniors lock first. Zero when the market
    /// has no debt, without consulting the oracle.
    /// @param tranche The tranche address
    /// @return value The locked capital value in USD (18 decimals)
    function lockedValue(address tranche) external view returns (uint256 value);

    /// @notice Get the total capital of the market
    /// @return capital The total capital in USD (18 decimals)
    function totalCapital() external view returns (uint256 capital);

    /// @notice Get the available credit
    /// @return credit The available credit in USD (18 decimals)
    function availableCredit() external view returns (uint256 credit);

    /// @notice Get the credit limit
    /// @dev Sum of each attached tranche's {ITranche-capitalLimit}, then `min(loanToValue, liquidationThreshold - buffer)`.
    /// Lowering `liquidationThreshold` or raising `buffer` caps new credit even when the stored `loanToValue` is higher.
    /// @return limit The credit limit in USD (18 decimals)
    function creditLimit() external view returns (uint256 limit);
}
