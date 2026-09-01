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

    /// @notice Emitted when an underwriter rate is set
    /// @param market The market that set the rate
    /// @param rate The new underwriter rate per year in ray decimals
    event SetUnderwriterRate(address indexed market, uint256 rate);

    /// @notice Emitted when liquidity slopes are set
    /// @param slopes The new liquidity slopes
    event SetLiquiditySlopes(Slopes slopes);

    /// @notice Emitted when term multiplier slopes are set
    /// @param slopes The new term multiplier slopes
    event SetTermMultiplierSlopes(Slopes slopes);

    /// @notice Emitted when a market multiplier is set
    /// @param market The market that set the multiplier
    /// @param multiplier The new market multiplier in ray decimals
    event SetMarketMultiplier(address indexed market, uint256 multiplier);

    /// @notice Emitted when the liquidation bonus is set
    /// @param liquidationBonus The new liquidation bonus in ray decimals
    event SetLiquidationBonus(uint256 liquidationBonus);

    /// @notice Initialize the interest rate model
    /// @param authority The address of the authority
    /// @param stablecoin The address of the Stablecoin token
    /// @param minimumMarketMultiplier The minimum market multiplier in ray decimals
    /// @param maximumMarketMultiplier The maximum market multiplier in ray decimals
    /// @param minimumUnderwriterRate The minimum underwriter rate per year in ray decimals
    /// @param maximumUnderwriterRate The maximum underwriter rate per year in ray decimals
    /// @param liquidationBonus The liquidation bonus in ray decimals
    function initialize(
        address authority,
        address stablecoin,
        uint256 minimumMarketMultiplier,
        uint256 maximumMarketMultiplier,
        uint256 minimumUnderwriterRate,
        uint256 maximumUnderwriterRate,
        uint256 liquidationBonus
    ) external;

    /// @notice Update the liquidity rate
    function updateLiquidityRate() external;

    /// @notice Set the liquidity slopes
    function setLiquiditySlopes(Slopes memory slopes) external;

    /// @notice Set the term multiplier slopes
    function setTermMultiplierSlopes(Slopes memory slopes) external;

    /// @notice Set the liquidation bonus
    /// @param liquidationBonus The liquidation bonus in ray decimals
    function setLiquidationBonus(uint256 liquidationBonus) external;

    /// @notice Set the underwriter rate for the calling market
    function setUnderwriterRate(uint256 rate) external;

    /// @notice Set the multiplier for the calling market
    function setMarketMultiplier(uint256 multiplier) external;

    /// @notice The address of the Stablecoin token
    function stablecoin() external view returns (address);

    /// @notice The slopes for the liquidity interest rate
    function liquiditySlopes() external view returns (uint256 base, uint256 slope0, uint256 slope1, uint256 kink);

    /// @notice The slopes for the term utilization multiplier
    function termMultiplierSlopes() external view returns (uint256 base, uint256 slope0, uint256 slope1, uint256 kink);

    /// @notice The minimum multiplier for a market's liquidity interest rate in ray decimals
    function minimumMarketMultiplier() external view returns (uint256);

    /// @notice The maximum multiplier for a market's liquidity interest rate in ray decimals
    function maximumMarketMultiplier() external view returns (uint256);

    /// @notice The minimum underwriter rate per year in ray decimals
    function minimumUnderwriterRate() external view returns (uint256);

    /// @notice The maximum underwriter rate per year in ray decimals
    function maximumUnderwriterRate() external view returns (uint256);

    /// @notice The fixed liquidation bonus in ray decimals
    function liquidationBonus() external view returns (uint256);

    /// @notice The data for the liquidity index
    function liquidityData() external view returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The data for the underwriter index of a market
    function underwriterData(address market)
        external
        view
        returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The current liquidity rate per year
    function liquidityRate() external view returns (uint256 rate);

    /// @notice The liquidity rate per year for a given term utilization
    function liquidityRate(uint256 termUtilization) external view returns (uint256 rate);

    /// @notice The current underwriter index for a market
    function underwriterIndex(address market) external view returns (uint256 index);

    /// @notice The current underwriter rate per year for a market
    function underwriterRate(address market) external view returns (uint256 rate);

    /// @notice The current multiplier for a market's liquidity interest rate in ray decimals
    function marketMultiplier(address market) external view returns (uint256 multiplier);

    /// @notice The current liquidity and underwriter indices for a market
    function indices(address market) external view returns (uint256 liquidity, uint256 underwriter);

    /// @notice The current liquidity index for a market
    function liquidityIndex(address market) external view returns (uint256 index);

    /// @notice The current fixed liquidity and underwriter rates for a market
    function fixedRates(address market, uint256 termUtilization)
        external
        view
        returns (uint256 liquidityRate, uint256 underwriterRate);

    /// @notice The multiplier for a given term utilization
    function termMultiplier(uint256 termUtilization) external view returns (uint256 multiplier);
}
