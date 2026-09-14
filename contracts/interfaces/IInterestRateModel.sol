// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IInterestRateModel
/// @author kexley, Cap Labs
/// @notice Interface for InterestRateModel contract
interface IInterestRateModel {
    /// @notice Invalid rate error
    error InvalidRate();

    /// @notice Invalid multiplier error
    error InvalidMultiplier();

    /// @notice Invalid liquidation bonus error
    error InvalidLiquidationBonus();

    /// @notice Invalid liquidity slopes error, the kink must not exceed full utilization
    error InvalidSlopes();

    /// @notice Invalid averaging period error, it must sit inside the bounded window
    error InvalidAveragingPeriod();

    /// @notice The data for an index
    /// @param ratePerYear The interest rate per year in ray decimals
    /// @param index The cumulative index
    /// @param lastUpdate The last update time
    struct RateData {
        uint256 ratePerYear;
        uint256 index;
        uint256 lastUpdate;
    }

    /// @notice Linear slopes with a kink point
    /// @param base The starting point on the y-axis
    /// @param slope0 The slope for the first segment
    /// @param slope1 The slope for the second segment
    /// @param kink The kink point
    struct Slopes {
        uint256 base;
        uint256 slope0;
        uint256 slope1;
        uint256 kink;
    }

    /// @notice Time-weighted supplies and the observation they are carried towards
    /// @dev `observed*` is the snapshot taken at `lastUpdate`. The averages move toward it as time
    /// passes; a snapshot just written has not stood yet, so it has no weight.
    /// @param credit The time-weighted credit-backed supply as of `lastUpdate`
    /// @param supply The time-weighted total supply as of `lastUpdate`
    /// @param observedCredit The credit-backed supply that has stood since `lastUpdate`
    /// @param observedSupply The total supply that has stood since `lastUpdate`
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
    /// @param slopes The new liquidity slopes
    event SetLiquiditySlopes(Slopes slopes);

    /// @notice Emitted when the term multiplier slope is set
    /// @param slope The new term multiplier slope in ray decimals
    event SetTermMultiplierSlope(uint256 slope);

    /// @notice Emitted when the liquidation bonus is set
    /// @param liquidationBonus The new liquidation bonus in ray decimals
    event SetLiquidationBonus(uint256 liquidationBonus);

    /// @notice Emitted when the averaging period is set
    /// @param averagingPeriod The new averaging period in seconds
    event SetAveragingPeriod(uint256 averagingPeriod);

    /// @notice Initialize the interest rate model
    /// @dev Same bounds as the setters.
    /// @param authority The access manager
    /// @param stablecoin The stablecoin
    /// @param minimumMarketMultiplier Minimum market multiplier in ray, at or below the maximum.
    /// Markets read this band in {IBaseMarket-setMarketMultiplier}.
    /// @param maximumMarketMultiplier Maximum market multiplier in ray
    /// @param maximumUnderwriterRate Maximum underwriter rate per year in ray
    /// @param liquidationBonus Liquidation bonus in ray
    /// @param averagingPeriod Averaging period in seconds, inside the bounded window
    function initialize(
        address authority,
        address stablecoin,
        uint256 minimumMarketMultiplier,
        uint256 maximumMarketMultiplier,
        uint256 maximumUnderwriterRate,
        uint256 liquidationBonus,
        uint256 averagingPeriod
    ) external;

    /// @notice Accrue the liquidity rate and fold the elapsed interval into the averages
    /// @dev Permissionless
    function updateLiquidityRate() external;

    /// @notice Set the liquidity slopes
    /// @param slopes Rate curve. Kink must not exceed one ray.
    function setLiquiditySlopes(Slopes memory slopes) external;

    /// @notice Set the term multiplier slope
    /// @param slope Excess over one ray at zero term. Zero makes the multiplier flat.
    function setTermMultiplierSlope(uint256 slope) external;

    /// @notice Set the liquidation bonus
    /// @param liquidationBonus The liquidation bonus in ray decimals
    function setLiquidationBonus(uint256 liquidationBonus) external;

    /// @notice Set the period the stablecoin supplies are averaged over
    /// @dev Bounded at both ends. Settles the running interval under the old window first.
    /// @param averagingPeriod The averaging period in seconds, inside the bounded window
    function setAveragingPeriod(uint256 averagingPeriod) external;

    /// @notice Update the underwriter rate for the calling market ({CapRoles-MARKET})
    /// @param rate The new underwriter rate per year in ray decimals
    function updateUnderwriterRate(uint256 rate) external;

    /// @notice The address of the Stablecoin token
    /// @return The stablecoin address
    function stablecoin() external view returns (address);

    /// @notice The slopes for the liquidity interest rate
    /// @return base The starting point on the y-axis
    /// @return slope0 The slope for the first segment
    /// @return slope1 The slope for the second segment
    /// @return kink The kink point
    function liquiditySlopes() external view returns (uint256 base, uint256 slope0, uint256 slope1, uint256 kink);

    /// @notice The excess term multiplier over one ray at a zero length term, in ray decimals
    /// @return The term multiplier slope
    function termMultiplierSlope() external view returns (uint256);

    /// @notice The minimum multiplier for a market's liquidity interest rate in ray decimals
    /// @return The minimum market multiplier
    function minimumMarketMultiplier() external view returns (uint256);

    /// @notice The maximum multiplier for a market's liquidity interest rate in ray decimals
    /// @return The maximum market multiplier
    function maximumMarketMultiplier() external view returns (uint256);

    /// @notice The maximum underwriter rate per year in ray decimals
    /// @return The maximum underwriter rate
    function maximumUnderwriterRate() external view returns (uint256);

    /// @notice The fixed liquidation bonus in ray decimals
    /// @return The liquidation bonus
    function liquidationBonus() external view returns (uint256);

    /// @notice Averaging period in seconds
    /// @dev Time constant. One period moves the average ~63% toward the observation.
    /// @return The averaging period in seconds
    function averagingPeriod() external view returns (uint256);

    /// @notice Share of the average that survives one second
    /// @dev Derived from {averagingPeriod}. Splitting an interval cannot change the result.
    /// @return The per-second retention factor
    function retentionPerSecond() external view returns (uint256);

    /// @notice The shortest averaging period governance may set, in seconds
    /// @return The minimum averaging period
    function MINIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice The longest averaging period governance may set, in seconds
    /// @return The maximum averaging period
    function MAXIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice The stored time-weighted supplies and the observation they are carried towards
    /// @return credit The time-weighted credit-backed supply as of `lastUpdate`
    /// @return supply The time-weighted total supply as of `lastUpdate`
    /// @return observedCredit The credit-backed supply that has stood since `lastUpdate`
    /// @return observedSupply The total supply that has stood since `lastUpdate`
    /// @return lastUpdate The time the averages were last folded forward
    function utilizationAverage()
        external
        view
        returns (uint256 credit, uint256 supply, uint256 observedCredit, uint256 observedSupply, uint256 lastUpdate);

    /// @notice Time-weighted supplies as they stand now
    /// @dev Same-block as a supply move, this is the stored pair.
    /// @return credit The time-weighted credit-backed supply
    /// @return supply The time-weighted total supply
    function averageSupplies() external view returns (uint256 credit, uint256 supply);

    /// @notice The time-weighted utilization rate
    /// @dev The carried averages only. Unabsorbed credit-backed mints are added by
    /// {averageUtilizationAfterMint}, not here.
    /// @return rate The time-weighted utilization rate in ray decimals
    function averageUtilization() external view returns (uint256 rate);

    /// @notice Credit-backed supply the time-weighted average has not yet absorbed
    /// @dev `max(0, live credit - average credit)`. A reserve-only move does not appear.
    /// @return amount The unsmoothed credit-backed supply
    function unsmoothedCredit() external view returns (uint256 amount);

    /// @notice Utilization after a credit-backed mint, against the time-weighted supplies
    /// @dev `mintAmount` and any already-unabsorbed credit are added in full. A same-tx reserve
    /// move still carries no weight.
    /// @param mintAmount The credit-backed supply about to be minted
    /// @return rate The projected utilization rate in ray decimals
    function averageUtilizationAfterMint(uint256 mintAmount) external view returns (uint256 rate);

    /// @notice The data for the liquidity index
    /// @return ratePerYear The interest rate per year in ray decimals
    /// @return index The cumulative index
    /// @return lastUpdate The last update time
    function liquidityData() external view returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The data for the underwriter index of a market
    /// @param market The market to query
    /// @return ratePerYear The interest rate per year in ray decimals
    /// @return index The cumulative index
    /// @return lastUpdate The last update time
    function underwriterData(address market)
        external
        view
        returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The current liquidity rate per year
    /// @return rate The liquidity rate per year in ray decimals
    function liquidityRate() external view returns (uint256 rate);

    /// @notice The current underwriter index for a market
    /// @param market The market to query
    /// @return index The underwriter index
    function underwriterIndex(address market) external view returns (uint256 index);

    /// @notice The current underwriter rate per year for a market
    /// @param market The market to query
    /// @return rate The underwriter rate per year in ray decimals
    function underwriterRate(address market) external view returns (uint256 rate);

    /// @notice The current global liquidity index
    /// @dev Unmultiplied. Floating markets grow a local index from this; fixed markets multiply
    /// the annual rate.
    /// @return index The liquidity index
    function liquidityIndex() external view returns (uint256 index);

    /// @notice Fixed rates after a credit-backed mint
    /// @dev Non-decreasing in `mintAmount`. See {averageUtilizationAfterMint}, which also folds
    /// in unabsorbed credit. The liquidity rate is the protocol curve times the term multiplier;
    /// the caller applies its market multiplier.
    /// @param market The market the underwriter rate is for
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @param mintAmount The credit-backed supply about to be minted
    /// @return liquidityRate The projected liquidity rate per year in ray decimals
    /// @return underwriterRate The underwriter rate per year in ray decimals
    function fixedRatesAfterMint(address market, uint256 termUtilization, uint256 mintAmount)
        external
        view
        returns (uint256 liquidityRate, uint256 underwriterRate);

    /// @notice Multiplier for a given term utilization
    /// @dev Linear from `1e27 + slope` at zero term down to `1e27`. Never below one ray.
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @return multiplier The multiplier in ray decimals, always at least one ray
    function termMultiplier(uint256 termUtilization) external view returns (uint256 multiplier);
}
