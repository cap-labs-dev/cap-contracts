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

    /// @notice The time-weighted stablecoin supplies, and the observation they are carried towards
    /// @dev The observation is the pair as it stood at the last accrual, kept because the accrual
    /// runs after the supplies have already moved and so cannot use the live reading; see
    /// {averageSupplies}.
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

    /// @notice Emitted when a market multiplier is set
    /// @param market The market that set the multiplier
    /// @param multiplier The new market multiplier in ray decimals
    event UpdateMarketMultiplier(address indexed market, uint256 multiplier);

    /// @notice Emitted when the liquidation bonus is set
    /// @param liquidationBonus The new liquidation bonus in ray decimals
    event SetLiquidationBonus(uint256 liquidationBonus);

    /// @notice Emitted when the averaging period is set
    /// @param averagingPeriod The new averaging period in seconds
    event SetAveragingPeriod(uint256 averagingPeriod);

    /// @notice Initialize the interest rate model
    /// @dev Validated against the same bounds the setters enforce, so a deployment cannot start
    /// outside the range governance is later allowed to move within. The multiplier band has no
    /// setter at all, so an inverted one would leave {updateMarketMultiplier} unsatisfiable for good.
    /// @param authority The address of the authority
    /// @param stablecoin The address of the Stablecoin token
    /// @param minimumMarketMultiplier The minimum market multiplier in ray decimals, at or below
    /// the maximum
    /// @param maximumMarketMultiplier The maximum market multiplier in ray decimals
    /// @param maximumUnderwriterRate The maximum underwriter rate per year in ray decimals
    /// @param liquidationBonus The liquidation bonus in ray decimals
    /// @param averagingPeriod The averaging period in seconds, inside the bounded window
    function initialize(
        address authority,
        address stablecoin,
        uint256 minimumMarketMultiplier,
        uint256 maximumMarketMultiplier,
        uint256 maximumUnderwriterRate,
        uint256 liquidationBonus,
        uint256 averagingPeriod
    ) external;

    /// @notice Update the liquidity rate, and fold the interval that has just ended into the
    /// time-weighted supplies
    /// @dev Called by the stablecoin after every move in either supply, which is what makes this
    /// the point the averages advance from. It is also permissionless, and safely so: an accrual
    /// forced at a moment of the caller's choosing credits the observation from before their own
    /// transaction and then leaves them a zero length interval to be weighted on.
    function updateLiquidityRate() external;

    /// @notice Set the liquidity slopes
    /// @param slopes The rate curve. The kink must not exceed one ray, since utilization cannot,
    /// and a kink beyond it would leave the second slope unreachable
    function setLiquiditySlopes(Slopes memory slopes) external;

    /// @notice Set the term multiplier slope
    /// @param slope The excess multiplier over one ray at a zero length term, in ray decimals.
    /// Zero makes the multiplier flat at one ray for every term.
    function setTermMultiplierSlope(uint256 slope) external;

    /// @notice Set the liquidation bonus
    /// @param liquidationBonus The liquidation bonus in ray decimals
    function setLiquidationBonus(uint256 liquidationBonus) external;

    /// @notice Set the period the stablecoin supplies are averaged over
    /// @dev Bounded at both ends. Shortening it towards zero converges on spot pricing and hands
    /// a flash borrower back the ability to mint a fixed loan against a utilization they created
    /// and unwound in the same transaction; lengthening it leaves fixed loans priced off liquidity
    /// conditions that have since moved on. The interval running when this is called is settled
    /// under the old window first, so a change never reweights time that has already passed.
    /// @param averagingPeriod The averaging period in seconds, inside the bounded window
    function setAveragingPeriod(uint256 averagingPeriod) external;

    /// @notice Update the underwriter rate for the calling market, which must hold {CapRoles-MARKET}
    function updateUnderwriterRate(uint256 rate) external;

    /// @notice Update the multiplier for the calling market, which must hold {CapRoles-MARKET}
    function updateMarketMultiplier(uint256 multiplier) external;

    /// @notice The address of the Stablecoin token
    function stablecoin() external view returns (address);

    /// @notice The slopes for the liquidity interest rate
    function liquiditySlopes() external view returns (uint256 base, uint256 slope0, uint256 slope1, uint256 kink);

    /// @notice The excess term multiplier over one ray at a zero length term, in ray decimals
    function termMultiplierSlope() external view returns (uint256);

    /// @notice The minimum multiplier for a market's liquidity interest rate in ray decimals
    function minimumMarketMultiplier() external view returns (uint256);

    /// @notice The maximum multiplier for a market's liquidity interest rate in ray decimals
    function maximumMarketMultiplier() external view returns (uint256);

    /// @notice The maximum underwriter rate per year in ray decimals
    function maximumUnderwriterRate() external view returns (uint256);

    /// @notice The fixed liquidation bonus in ray decimals
    function liquidationBonus() external view returns (uint256);

    /// @notice The period the stablecoin supplies are averaged over, in seconds
    /// @dev The window a manipulation has to be sustained across to be fully reflected, and equally
    /// the lag before a genuine shift in utilization is fully priced into new fixed loans
    function averagingPeriod() external view returns (uint256);

    /// @notice The shortest averaging period governance may set, in seconds
    function MINIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice The longest averaging period governance may set, in seconds
    function MAXIMUM_AVERAGING_PERIOD() external view returns (uint256);

    /// @notice The stored time-weighted supplies and the observation they are carried towards
    function utilizationAverage()
        external
        view
        returns (uint256 credit, uint256 supply, uint256 observedCredit, uint256 observedSupply, uint256 lastUpdate);

    /// @notice The time-weighted stablecoin supplies as they stand now
    /// @dev The stored averages carried the share of the way towards the standing observation that
    /// the time since the last accrual has earned, so this moves with the clock rather than only
    /// when a supply does. In the same block as a supply move it is exactly the stored pair, since
    /// the reading that has just arrived has stood for no time.
    /// @return credit The time-weighted credit-backed supply
    /// @return supply The time-weighted total supply
    function averageSupplies() external view returns (uint256 credit, uint256 supply);

    /// @notice The time-weighted utilization rate
    /// @dev {averageUtilizationAfterMint} with nothing about to be minted
    /// @return rate The time-weighted utilization rate in ray decimals
    function averageUtilization() external view returns (uint256 rate);

    /// @notice The utilization rate a credit-backed mint would leave behind, measured against the
    /// time-weighted supplies rather than the live ones
    /// @dev What a fixed-term premium is priced off. {IStablecoin-deposit} and {IStablecoin-redeem}
    /// are permissionless and round-trip at par with no fee, so the live utilization can be moved
    /// and moved back inside one transaction for the cost of the gas. A floating loan shrugs that
    /// off because its index re-accrues at the next move, but a fixed loan mints its whole term's
    /// premium upfront at whatever it reads in that block, so a single observation was being
    /// charged for up to a month — cheaper for a borrower who suppressed it, dearer for a victim
    /// whose lender-to-be inflated it.
    ///
    /// Averaging over {averagingPeriod} removes the atomic version of that outright: a reading that
    /// has stood for no time carries no weight, so a supply moved and restored within one
    /// transaction never enters the average at all. What remains is a manipulation held across
    /// blocks, which is no longer free — it means standing behind an unwanted position for a real
    /// share of the period, exposed to everyone else the whole time.
    ///
    /// The mint itself is still charged in full. It is added to the averaged supplies rather than
    /// smoothed away, so a borrower pays for the utilization their own draw creates even though the
    /// level they draw on top of is a time-weighted one.
    /// @param mintAmount The credit-backed supply about to be minted
    /// @return rate The projected utilization rate in ray decimals
    function averageUtilizationAfterMint(uint256 mintAmount) external view returns (uint256 rate);

    /// @notice The data for the liquidity index
    function liquidityData() external view returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The data for the underwriter index of a market
    function underwriterData(address market)
        external
        view
        returns (uint256 ratePerYear, uint256 index, uint256 lastUpdate);

    /// @notice The current liquidity rate per year
    function liquidityRate() external view returns (uint256 rate);

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

    /// @notice The fixed rates a market would face once a credit-backed mint had landed
    /// @dev A fixed borrow mints its principal before its premium is priced, so the premium is
    /// charged on the far side of the utilization its own mint created. This is how that rate can
    /// be read beforehand, which is what lets the loan be sized against the rate it will actually
    /// pay. Non-decreasing in `mintAmount`, since both the utilization projection and the slope
    /// curve are; see {averageUtilizationAfterMint}.
    /// @param market The market the rates are for
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @param mintAmount The credit-backed supply about to be minted
    /// @return liquidityRate The projected liquidity rate per year in ray decimals
    /// @return underwriterRate The underwriter rate per year in ray decimals
    function fixedRatesAfterMint(address market, uint256 termUtilization, uint256 mintAmount)
        external
        view
        returns (uint256 liquidityRate, uint256 underwriterRate);

    /// @notice The multiplier for a given term utilization
    /// @dev Single linear curve decaying from `1e27 + slope` at a zero length term down to `1e27`
    /// at the maximum term, and flat at `1e27` beyond it. Short terms therefore pay a premium over
    /// the liquidity rate and long terms pay the rate itself; the multiplier never reaches zero, so
    /// no term is ever free.
    /// @param termUtilization The term as a fraction of the market's maximum term in ray decimals
    /// @return multiplier The multiplier in ray decimals, always at least one ray
    function termMultiplier(uint256 termUtilization) external view returns (uint256 multiplier);
}
