// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IBaseMarket
/// @author kexley, Cap Labs
/// @notice Shared interface for fixed and floating market implementations
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
    /// @param stakedStablecoin The staked stablecoin address
    /// @param irm The interest rate model address
    /// @param targetHealth The target health in ray decimals
    /// @param ltv The loan-to-value ratio in ray decimals
    /// @param buffer The liquidation buffer in ray decimals
    /// @param lt The liquidation threshold in ray decimals
    /// @param fixedCreditLimit The fixed credit limit
    /// @param tranches The tranches and their weights
    struct BaseMarketStorage {
        string name;
        address stablecoin;
        address stakedStablecoin;
        address irm;
        uint256 targetHealth;
        uint256 ltv;
        uint256 buffer;
        uint256 lt;
        uint256 fixedCreditLimit;
        Tranche[] tranches;
    }

    /// @notice The loan-to-value ratio exceeds the liquidation threshold minus buffer
    error InvalidLtv();

    /// @notice The buffer exceeds the maximum allowed value
    error InvalidBuffer();

    /// @notice The liquidation threshold exceeds the maximum allowed value
    error InvalidLt();

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

    /// @notice Insufficient liquidity for the requested borrow
    error InsufficientLiquidity();

    /// @notice The tranche weights do not sum to one ray
    error InvalidTrancheWeightsTotal();

    /// @notice The tranche is already set
    error TrancheAlreadySet();

    /// @notice Emitted when assets are borrowed from the market
    /// @param recipient The address receiving the borrowed assets
    /// @param principal The amount borrowed
    event Borrow(address recipient, uint256 principal);

    /// @notice Emitted when debt is repaid to the market
    /// @param caller The address repaying the debt
    /// @param amount The amount repaid
    event Repay(address caller, uint256 amount);

    /// @notice Emitted when an unhealthy position is liquidated
    /// @param caller The address initiating the liquidation
    /// @param recipient The address receiving slashed assets
    /// @param repaid The amount of debt repaid
    /// @param assetsSlashed The amount of tranche assets slashed
    event Liquidate(address caller, address recipient, uint256 repaid, uint256 assetsSlashed);

    /// @notice Emitted when the loan-to-value ratio is updated
    /// @param ltv The new loan-to-value ratio in ray decimals
    event SetLtv(uint256 ltv);

    /// @notice Emitted when the liquidation buffer is updated
    /// @param buffer The new buffer in ray decimals
    event SetBuffer(uint256 buffer);

    /// @notice Emitted when the liquidation threshold is updated
    /// @param lt The new liquidation threshold in ray decimals
    event SetLt(uint256 lt);

    /// @notice Emitted when the fixed credit limit is updated
    /// @param fixedCreditLimit The new fixed credit limit
    event SetFixedCreditLimit(uint256 fixedCreditLimit);

    /// @notice Emitted when the target health is updated
    /// @param targetHealth The new target health in ray decimals
    event SetTargetHealth(uint256 targetHealth);

    /// @notice Emitted when the staked stablecoin is updated
    /// @param stakedStablecoin The new staked stablecoin address
    event SetStakedStablecoin(address stakedStablecoin);

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
    /// @param premium The amount of premium minted
    event ChargePremium(address indexed recipient, uint256 premium);

    /// @notice Set the loan-to-value ratio
    /// @param ltv The new loan-to-value ratio in ray decimals
    function setLtv(uint256 ltv) external;

    /// @notice Set the liquidation buffer
    /// @param buffer The new buffer in ray decimals
    function setBuffer(uint256 buffer) external;

    /// @notice Set the liquidation threshold
    /// @param lt The new liquidation threshold in ray decimals
    function setLt(uint256 lt) external;

    /// @notice Set the fixed credit limit
    /// @param fixedCreditLimit The new fixed credit limit
    function setFixedCreditLimit(uint256 fixedCreditLimit) external;

    /// @notice Set the target health
    /// @param targetHealth The new target health in ray decimals
    function setTargetHealth(uint256 targetHealth) external;

    /// @notice Set the staked stablecoin
    /// @param stakedStablecoin The new staked stablecoin address
    function setStakedStablecoin(address stakedStablecoin) external;

    /// @notice Set the tranches and their weights
    /// @param tranches The new tranche addresses and weights
    function setTranches(Tranche[] calldata tranches) external;

    /// @notice Set the tranche weights
    /// @param weights The new tranche weights in ray decimals
    function setTrancheWeights(uint256[] calldata weights) external;

    /// @notice Set the underwriter rate
    /// @param rate The new underwriter rate per year in ray decimals
    function setUnderwriterRate(uint256 rate) external;

    /// @notice Set the market multiplier
    /// @dev On a floating market this reindexes scaled debt so outstanding principal is unchanged
    /// @param multiplier The new market multiplier in ray decimals
    function setMarketMultiplier(uint256 multiplier) external;

    /// @notice Get the market name
    function name() external view returns (string memory);

    /// @notice Get the stablecoin address
    function stablecoin() external view returns (address);

    /// @notice Get the staked stablecoin address
    function stakedStablecoin() external view returns (address);

    /// @notice Get the interest rate model address
    function irm() external view returns (address);

    /// @notice Get the liquidation threshold in ray decimals
    function lt() external view returns (uint256);

    /// @notice Get the liquidation buffer in ray decimals
    function buffer() external view returns (uint256);

    /// @notice Get the target health in ray decimals
    function targetHealth() external view returns (uint256);

    /// @notice Get the loan-to-value ratio in ray decimals
    function ltv() external view returns (uint256);

    /// @notice Get the fixed credit limit
    function fixedCreditLimit() external view returns (uint256);

    /// @notice Get the tranche addresses and weights
    /// @return tranches The tranches and their weights
    function tranches() external view returns (Tranche[] memory tranches);

    /// @notice Get the total debt of the market
    /// @return debt The total outstanding debt
    function totalDebt() external view returns (uint256 debt);

    /// @notice Get the debt level at which the market hits its liquidation threshold
    /// @return threshold The liquidation threshold expressed as debt capacity
    function debtLiquidationThreshold() external view returns (uint256 threshold);

    /// @notice Get the healthiness of the market
    /// @return health The healthiness in ray decimals
    function healthiness() external view returns (uint256 health);

    /// @notice Get the utilization of the market
    /// @return utilization The utilization in ray decimals
    function utilization() external view returns (uint256 utilization);

    /// @notice Get the maximum liquidatable debt
    /// @return liquidatable The maximum liquidatable debt
    function maxLiquidatable() external view returns (uint256 liquidatable);

    /// @notice Get the capital value a tranche must keep locked to back the market's debt
    /// @dev Denominated in USD (18 decimals), not in collateral tokens. More junior tranches are
    /// locked first, so a tranche only locks what the tranches below it cannot cover. Callers
    /// holding collateral must convert at the oracle price before comparing against balances.
    /// @param tranche The tranche address
    /// @return value The locked capital value in USD (18 decimals)
    function lockedValue(address tranche) external view returns (uint256 value);

    /// @notice Get the total capital of the market
    /// @return capital The total capital
    function totalCapital() external view returns (uint256 capital);

    /// @notice Get the available credit
    /// @return credit The available credit
    function availableCredit() external view returns (uint256 credit);

    /// @notice Get the credit limit
    /// @return limit The credit limit
    function creditLimit() external view returns (uint256 limit);

    /// @notice Get the variable credit limit
    /// @return limit The variable credit limit
    function variableCreditLimit() external view returns (uint256 limit);
}
