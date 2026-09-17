// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IInterestRateModel
/// @author kexley, Cap Labs
/// @notice Interface for the protocol interest rate model
interface IInterestRateModel {
    /// @notice The rate is invalid
    error InvalidRate();

    /// @notice The multiplier is invalid
    error InvalidMultiplier();

    /// @notice The liquidation bonus is invalid
    error InvalidLiquidationBonus();

    /// @notice The kink must not exceed full utilization
    error InvalidSlopes();

    /// @notice The averaging period must sit inside the bounded window
    error InvalidAveragingPeriod();

    /// @notice The default liquidation threshold is invalid
    error InvalidLiquidationThreshold();

    /// @notice The default liquidation buffer is invalid
    error InvalidBuffer();

    /// @notice The default target health is below the minimum
    error InvalidTargetHealth();

    /// @notice The data for an index
    /// @param ratePerYear The interest rate per year in ray decimals
    /// @param index The cumulative index in ray decimals
    /// @param lastUpdate The last update time
    struct RateData {
        uint256 ratePerYear;
        uint256 index;
        uint256 lastUpdate;
    }

    /// @notice Linear slopes with a kink point
    /// @param base The starting point on the y-axis, in ray decimals
    /// @param slope0 The slope for the first segment, in ray decimals
    /// @param slope1 The slope for the second segment, in ray decimals
    /// @param kink The kink point, in ray decimals
    struct Slopes {
        uint256 base;
        uint256 slope0;
        uint256 slope1;
        uint256 kink;
    }

    /// @notice Time-weighted supplies and the observation they are carried towards
    /// @dev `observed*` is the snapshot taken at `lastUpdate`. The averages move toward it as time
    /// passes; a snapshot just written has not stood yet, so it has no weight.
    /// @param credit The time-weighted credit-backed supply as of `lastUpdate`, in stablecoin units (18 decimals)
    /// @param supply The time-weighted total supply as of `lastUpdate`, in stablecoin units (18 decimals)
    /// @param observedCredit The credit-backed supply that has stood since `lastUpdate`, in stablecoin units (18 decimals)
    /// @param observedSupply The total supply that has stood since `lastUpdate`, in stablecoin units (18 decimals)
    /// @param lastUpdate The time the averages were last folded forward
    struct UtilizationAverage {
        uint256 credit;
        uint256 supply;
        uint256 observedCredit;
        uint256 observedSupply;
        uint256 lastUpdate;
    }

    /// @notice Emitted when an underwriter rate is set
    /// @param market The market that set the rate
    /// @param rate The new underwriter rate per year in ray decimals
    event UpdateUnderwriterRate(address indexed market, uint256 rate);

    /// @notice Emitted when liquidity slopes are set
    /// @param slopes The new liquidity slopes, in ray decimals
    event SetLiquiditySlopes(Slopes slopes);

    /// @notice Emitted when the live liquidity rate and index are checkpointed
    /// @param ratePerYear The liquidity rate per year in ray decimals
    /// @param index The checkpointed liquidity index in ray decimals
    event LiquidityRateUpdated(uint256 ratePerYear, uint256 index);

    /// @notice Emitted when a market's underwriter index is checkpointed
    /// @param market The market whose index was written
    /// @param index The checkpointed underwriter index in ray decimals
    event UnderwriterIndexUpdated(address indexed market, uint256 index);

    /// @notice Emitted when the term multiplier slope is set
    /// @param slope The new term multiplier slope in ray decimals
    event SetTermMultiplierSlope(uint256 slope);

    /// @notice Emitted when the liquidation bonus is set
    /// @param liquidationBonus The new liquidation bonus in ray decimals
    event SetLiquidationBonus(uint256 liquidationBonus);

    /// @notice Emitted when the averaging period is set
    /// @param averagingPeriod The new averaging period in seconds
    event SetAveragingPeriod(uint256 averagingPeriod);

    /// @notice Emitted when the default liquidation threshold is set
    /// @param liquidationThreshold The new default liquidation threshold in ray decimals
    event SetLiquidationThreshold(uint256 liquidationThreshold);

    /// @notice Emitted when the default liquidation buffer is set
    /// @param buffer The new default liquidation buffer in ray decimals
    event SetBuffer(uint256 buffer);

    /// @notice Emitted when the default target health is set
    /// @param targetHealth The new default target health in ray decimals
    event SetTargetHealth(uint256 targetHealth);

    /// @notice Initialize the interest rate model
    /// @dev Same bounds as the setters.
    /// @param authority The access manager address
    /// @param stablecoin The stablecoin address
    /// @param minimumMarketMultiplier The minimum market multiplier in ray decimals, at or below the maximum.
    /// Markets read this band in {IBaseMarket-setMarketMultiplier}.
    /// @param maximumMarketMultiplier The maximum market multiplier in ray decimals
    /// @param maximumUnderwriterRate The maximum underwriter rate per year in ray decimals
    /// @param liquidationBonus The liquidation bonus in ray decimals
    /// @param averagingPeriod The averaging period in seconds, inside the bounded window
    /// @param liquidationThreshold The default liquidation threshold for new markets in ray decimals
    /// @param buffer The default liquidation buffer for new markets in ray decimals
    /// @param targetHealth The default target health for new markets in ray decimals
    function initialize(
        address authority,
        address stablecoin,
        uint256 minimumMarketMultiplier,
        uint256 maximumMarketMultiplier,
        uint256 maximumUnderwriterRate,
        uint256 liquidationBonus,
        uint256 averagingPeriod,
        uint256 liquidationThreshold,
        uint256 buffer,
        uint256 targetHealth
    ) external;

    /// @notice Accrue the liquidity rate and fold the elapsed interval into the averages
    /// @dev Permissionless
    function updateLiquidityRate() external;

    /// @notice Set the liquidity slopes
    /// @param slopes The rate curve in ray decimals. The kink must not exceed one ray.
    function setLiquiditySlopes(Slopes memory slopes) external;

    /// @notice Set the term multiplier slope
    /// @param slope The excess over one ray at zero term, in ray decimals. Zero makes the multiplier flat.
    function setTermMultiplierSlope(uint256 slope) external;

    /// @notice Set the liquidation bonus
    /// @param liquidationBonus The liquidation bonus in ray decimals
    function setLiquidationBonus(uint256 liquidationBonus) external;

    /// @notice Set the period the stablecoin supplies are averaged over
    /// @dev Bounded at both ends. Settles the running interval under the old window first.
    /// @param averagingPeriod The averaging period in seconds, inside the bounded window
    function setAveragingPeriod(uint256 averagingPeriod) external;

    /// @notice Set the default liquidation threshold copied onto new markets
    /// @param liquidationThreshold The default liquidation threshold in ray decimals
    function setLiquidationThreshold(uint256 liquidationThreshold) external;

    /// @notice Set the default liquidation buffer copied onto new markets
    /// @param buffer The default liquidation buffer in ray decimals
    function setBuffer(uint256 buffer) external;

    /// @notice Set the default target health copied onto new markets
    /// @param targetHealth The default target health in ray decimals
    function setTargetHealth(uint256 targetHealth) external;

    /// @notice Update the underwriter rate for the calling market ({CapRoles-MARKET})
    /// @dev Checkpoints the index first so the new rate applies only going forward.
    /// @param rate The new underwriter rate per year in ray decimals
    function updateUnderwriterRate(uint256 rate) external;

    /// @notice Fold a market's underwriter index up to now
    /// @dev Permissionless. Does not change the rate. Anyone can keep a long-idle market current.
    /// @param market The market whose index to checkpoint
    function updateUnderwriterIndex(address market) external;

    /// @notice Get the stablecoin address
    /// @return The stablecoin address
    function stablecoin() external view returns (address);

    /// @notice Get the slopes for the liquidity interest rate
    /// @return base The starting point on the y-axis, in ray decimals
    /// @return slope0 The slope for the first segment, in ray decimals
    /// @return slope1 The slope for the second segment, in ray decimals
    /// @return kink The kink point, in ray decimals
    function liquiditySlopes() external view returns (uint256 base, uint256 slope0, uint256 slope1, uint256 kink);

    /// @notice Get the excess term multiplier over one ray at a zero length term, in ray decimals
    /// @return The term multiplier slope in ray decimals
    function termMultiplierSlope() external view returns (uint256);

    /// @notice Get the minimum multiplier for a market's liquidity interest rate in ray decimals
    /// @return The minimum market multiplier in ray decimals
    function minimumMarketMultiplier() external view returns (uint256);

    /// @notice Get the maximum multiplier for a market's liquidity interest rate in ray decimals
    /// @return The maximum market multiplier in ray decimals
    function maximumMarketMultiplier() external view returns (uint256);

    /// @notice Get the maximum underwriter rate per year in ray decimals
    /// @return The maximum underwriter rate in ray decimals
    function maximumUnderwriterRate() external view returns (uint256);

    /// @notice Get the fixed liquidation bonus in ray decimals
    /// @return The liquidation bonus in ray decimals
    function liquidationBonus() external view returns (uint256);

    /// @notice Get the default liquidation threshold for new markets in ray decimals
    /// @return The default liquidation threshold in ray decimals
    function liquidationThreshold() external view returns (uint256);

    /// @notice Get the default liquidation buffer for new markets in ray decimals
    /// @return The default liquidation buffer in ray decimals
    function buffer() external view returns (uint256);

    /// @notice Get the default target health for new markets in ray decimals
    /// @return The default target health in ray decimals
    function targetHealth() external view returns (uint256);

    /// @notice Get the averaging period in seconds
    /// @dev Time constant. One period moves the average ~63% toward the observation.
    /// @return The averaging period in seconds
    function averagingPeriod() external view returns (uint256);

    /// @notice Get the share of the average that survives one second
    /// @dev Derived from {averagingPeriod}. Splitting an interval is mathematically identical,
    /// subject to fixed-point rounding in {WadRayMath-rayPow}.
    /// @return The per-second retention factor in ray decimals
    function retentionPerSecond() external view returns (uint256);

    /// @notice Get the shortest averaging period governance may set, in seconds
    /// @return The minimum averaging period
    function MINIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice Get the longest averaging period governance may set, in seconds
    /// @return The maximum averaging period
    function MAXIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice Get the stored time-weighted supplies and the observation they are carried towards
    /// @return credit The time-weighted credit-backed supply as of `lastUpdate`, in stablecoin units (18 decimals)
    /// @return supply The time-weighted total supply as of `lastUpdate`, in stablecoin units (18 decimals)
    /// @return observedCredit The credit-backed supply that has stood since `lastUpdate`, in stablecoin units (18 decimals)
    /// @return observedSupply The total supply that has stood since `lastUpdate`, in stablecoin units (18 decimals)
    /// @return lastUpdate The time the averages were last folded forward
    function utilizationAverage()
        external
        view
        returns (uint256 credit, uint256 supply, uint256 observedCredit, uint256 observedSupply, uint256 lastUpdate);

    /// @notice Get the time-weighted supplies as they stand now
    /// @dev Same-block as a supply move, this is the stored pair.
    /// @return credit The time-weighted credit-backed supply, in stablecoin units (18 decimals)
    /// @return supply The time-weighted total supply, in stablecoin units (18 decimals)
    function averageSupplies() external view returns (uint256 credit, uint256 supply);

    /// @notice Get the time-weighted utilization rate
    /// @dev The carried averages only. Unabsorbed credit-backed mints are added by
    /// {averageUtilizationAfterMint}, not here.
    /// @return rate The time-weighted utilization rate in ray decimals
    function averageUtilization() external view returns (uint256 rate);

    /// @notice Get the credit-backed supply the time-weighted average has not yet absorbed
    /// @dev `max(0, live credit - average credit)`. A reserve-only move does not appear.
    /// @return amount The unsmoothed credit-backed supply, in stablecoin units (18 decimals)
    function unsmoothedCredit() external view returns (uint256 amount);

    /// @notice Get the utilization after a credit-backed mint, against the time-weighted supplies
    /// @dev `mintAmount` and any already-unabsorbed credit are added in full. A same-tx reserve
    /// move still carries no weight.
    /// @param mintAmount The credit-backed supply about to be minted, in stablecoin units (18 decimals)
    /// @return rate The projected utilization rate in ray decimals
    function averageUtilizationAfterMint(uint256 mintAmount) external view returns (uint256 rate);

    /// @notice Get the data for the liquidity index
    /// @return ratePerYear The interest rate per year in ray decimals
    /// @return index The cumulative index in ray decimals
    /// @return lastUpdate The last update time
    function liquidityData() external view returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice Get the data for the underwriter index of a market
    /// @param market The market to query
    /// @return ratePerYear The interest rate per year in ray decimals
    /// @return index The cumulative index in ray decimals
    /// @return lastUpdate The last update time
    function underwriterData(address market)
        external
        view
        returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice Get the current liquidity rate per year
    /// @return rate The liquidity rate per year in ray decimals
    function liquidityRate() external view returns (uint256 rate);

    /// @notice Get the current underwriter index for a market
    /// @dev Compounds in year-sized windows, so a long gap since the last write does not
    /// collapse onto a single cubic.
    /// @param market The market to query
    /// @return index The underwriter index in ray decimals
    function underwriterIndex(address market) external view returns (uint256 index);

    /// @notice Get the current underwriter rate per year for a market
    /// @param market The market to query
    /// @return rate The underwriter rate per year in ray decimals
    function underwriterRate(address market) external view returns (uint256 rate);

    /// @notice Get the current global liquidity index
    /// @dev Unmultiplied. Floating markets grow a local index from this; fixed markets multiply
    /// the annual rate.
    /// @return index The liquidity index in ray decimals
    function liquidityIndex() external view returns (uint256 index);

    /// @notice Get the fixed rates after a credit-backed mint
    /// @dev Non-decreasing in `mintAmount`. See {averageUtilizationAfterMint}, which also folds
    /// in unabsorbed credit. The liquidity rate is the protocol curve times the term multiplier;
    /// the caller applies its market multiplier.
    /// @param market The market the underwriter rate is for
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @param mintAmount The credit-backed supply about to be minted, in stablecoin units (18 decimals)
    /// @return liquidityRate The projected liquidity rate per year in ray decimals
    /// @return underwriterRate The underwriter rate per year in ray decimals
    function fixedRatesAfterMint(address market, uint256 termUtilization, uint256 mintAmount)
        external
        view
        returns (uint256 liquidityRate, uint256 underwriterRate);

    /// @notice Get the multiplier for a given term utilization
    /// @dev Linear from `1e27 + slope` at zero term down to `1e27`. Never below one ray.
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @return multiplier The multiplier in ray decimals, always at least one ray
    function termMultiplier(uint256 termUtilization) external view returns (uint256 multiplier);
}
