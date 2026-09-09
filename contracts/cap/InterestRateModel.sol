// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { MathUtils } from "../utils/MathUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title InterestRateModel
/// @author kexley, Cap Labs
/// @notice The InterestRateModel calculates the canonical variable and fixed interest rates for Stablecoin.
contract InterestRateModel layout at erc7201("cap.storage.InterestRateModel")
    is
    IInterestRateModel,
    UUPSUpgradeable,
    AccessManagedUpgradeable
{
    using WadRayMath for uint256;

    /// @inheritdoc IInterestRateModel
    address public stablecoin;

    /// @inheritdoc IInterestRateModel
    Slopes public liquiditySlopes;

    /// @inheritdoc IInterestRateModel
    uint256 public termMultiplierSlope;

    /// @dev Per-market liquidity rate multiplier in ray decimals
    mapping(address => uint256) private _marketMultiplier;

    /// @inheritdoc IInterestRateModel
    uint256 public minimumMarketMultiplier;

    /// @inheritdoc IInterestRateModel
    uint256 public maximumMarketMultiplier;

    /// @inheritdoc IInterestRateModel
    uint256 public maximumUnderwriterRate;

    /// @inheritdoc IInterestRateModel
    RateData public liquidityData;

    /// @inheritdoc IInterestRateModel
    mapping(address market => RateData data) public underwriterData;

    /// @inheritdoc IInterestRateModel
    uint256 public liquidationBonus;

    /// @inheritdoc IInterestRateModel
    UtilizationAverage public utilizationAverage;

    /// @inheritdoc IInterestRateModel
    uint256 public averagingPeriod;

    /// @inheritdoc IInterestRateModel
    uint256 public constant MINIMUM_AVERAGING_PERIOD = 5 minutes;

    /// @inheritdoc IInterestRateModel
    uint256 public constant MAXIMUM_AVERAGING_PERIOD = 1 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IInterestRateModel
    function initialize(
        address _authority,
        address _stablecoin,
        uint256 _minimumMarketMultiplier,
        uint256 _maximumMarketMultiplier,
        uint256 _maximumUnderwriterRate,
        uint256 _liquidationBonus,
        uint256 _averagingPeriod
    ) external initializer {
        __AccessManaged_init(_authority);
        // the multiplier band has no setter, so an inverted one would leave
        // {updateMarketMultiplier} permanently unsatisfiable with no way to repair it
        if (_minimumMarketMultiplier > _maximumMarketMultiplier) revert InvalidMultiplier();
        stablecoin = _stablecoin;
        minimumMarketMultiplier = _minimumMarketMultiplier;
        maximumMarketMultiplier = _maximumMarketMultiplier;
        maximumUnderwriterRate = _maximumUnderwriterRate;
        liquidityData.index = 1e27;
        liquidityData.lastUpdate = block.timestamp;
        // the stablecoin is deployed after this and its address only precomputed, so there is
        // nothing to observe yet. Start the clock so the first accrual credits the interval from
        // deployment rather than from the epoch
        utilizationAverage.lastUpdate = block.timestamp;
        _setLiquidationBonus(_liquidationBonus);
        _setAveragingPeriod(_averagingPeriod);
    }

    /// @inheritdoc IInterestRateModel
    function updateLiquidityRate() external {
        _updateLiquidityRate();
    }

    /// @inheritdoc IInterestRateModel
    function setLiquiditySlopes(Slopes memory _slopes) external restricted {
        // Utilization is a ratio of supplies and so never exceeds one ray, which makes a kink above
        // one ray unreachable: the second slope becomes dead and the curve silently tops out below
        // `base + slope0` instead of at `base + slope0 + slope1`. A kink entered as 8e27 rather
        // than 0.8e27 would therefore under-charge every borrower for as long as nobody noticed,
        // which is the kind of misconfiguration worth failing on rather than absorbing.
        if (_slopes.kink > 1e27) revert InvalidSlopes();
        liquiditySlopes = _slopes;
        _updateLiquidityRate();
        emit SetLiquiditySlopes(_slopes);
    }

    /// @inheritdoc IInterestRateModel
    function liquidityRate() public view returns (uint256 rate) {
        rate = liquidityData.ratePerYear;
    }

    /// @inheritdoc IInterestRateModel
    /// @dev There is no lower bound: a market may set its underwriter rate to zero
    function updateUnderwriterRate(uint256 rate) external restricted {
        if (rate > maximumUnderwriterRate) revert InvalidRate();
        address market = msg.sender;
        underwriterData[market].index = underwriterIndex(market);
        underwriterData[market].lastUpdate = block.timestamp;
        underwriterData[market].ratePerYear = rate;
        emit UpdateUnderwriterRate(market, rate);
    }

    /// @inheritdoc IInterestRateModel
    function underwriterIndex(address market) public view returns (uint256 index) {
        index = _index(underwriterData[market]);
    }

    /// @inheritdoc IInterestRateModel
    function underwriterRate(address market) public view returns (uint256 rate) {
        rate = underwriterData[market].ratePerYear;
    }

    /// @inheritdoc IInterestRateModel
    function updateMarketMultiplier(uint256 _multiplier) external restricted {
        address market = msg.sender;
        if (_multiplier < minimumMarketMultiplier || _multiplier > maximumMarketMultiplier) revert InvalidMultiplier();
        _marketMultiplier[market] = _multiplier;
        emit UpdateMarketMultiplier(market, _multiplier);
    }

    /// @inheritdoc IInterestRateModel
    function marketMultiplier(address market) public view returns (uint256 multiplier) {
        multiplier = _marketMultiplier[market];
        if (multiplier == 0) multiplier = 1e27;
    }

    /// @inheritdoc IInterestRateModel
    function indices(address market) public view returns (uint256 liquidity, uint256 underwriter) {
        liquidity = liquidityIndex(market);
        underwriter = underwriterIndex(market);
    }

    /// @inheritdoc IInterestRateModel
    function liquidityIndex(address market) public view returns (uint256 index) {
        index = _index(liquidityData).rayMul(marketMultiplier(market));
    }

    /// @inheritdoc IInterestRateModel
    function setTermMultiplierSlope(uint256 _slope) external restricted {
        termMultiplierSlope = _slope;
        emit SetTermMultiplierSlope(_slope);
    }

    /// @inheritdoc IInterestRateModel
    /// @dev The only route to a fixed rate, and it deliberately does not reuse {liquidityRate}.
    /// A floating loan is repriced every time the supplies move and its index re-accrues, so spot
    /// is the honest reading for it and a stale one would be wrong. A fixed loan locks its whole
    /// term's premium in the block it is taken, which turns a single observation into up to a
    /// month of charge, so it builds on the time-weighted figure instead; see
    /// {averageUtilizationAfterMint}.
    function fixedRatesAfterMint(address market, uint256 termUtilization, uint256 mintAmount)
        public
        view
        returns (uint256 liquidity, uint256 underwriter)
    {
        uint256 projected = _nextLiquidityRate(averageUtilizationAfterMint(mintAmount));
        liquidity = projected.rayMul(termMultiplier(termUtilization)).rayMul(marketMultiplier(market));
        underwriter = underwriterRate(market);
    }

    /// @inheritdoc IInterestRateModel
    function termMultiplier(uint256 termUtilization) public view returns (uint256 multiplier) {
        // a term at or beyond the maximum pays the plain liquidity rate. Both branches meet at one
        // ray, so the curve is continuous there and never dips below it
        if (termUtilization >= 1e27) return 1e27;
        multiplier = 1e27 + termMultiplierSlope.rayMul(1e27 - termUtilization);
    }

    /// @inheritdoc IInterestRateModel
    function setLiquidationBonus(uint256 _liquidationBonus) external restricted {
        _setLiquidationBonus(_liquidationBonus);
    }

    /// @dev Shared with {initialize} so a deployment cannot start outside the band governance is
    /// allowed to move within. The bonus feeds {BaseMarket-_slashPerDebt}, which sets what every
    /// liquidation takes out of the tranches, and the only route back from an out-of-range value
    /// would have been a setter that rejects the value already stored.
    /// @param _liquidationBonus The liquidation bonus in ray decimals
    function _setLiquidationBonus(uint256 _liquidationBonus) internal {
        if (_liquidationBonus > 0.1e27) revert InvalidLiquidationBonus();
        liquidationBonus = _liquidationBonus;
        emit SetLiquidationBonus(_liquidationBonus);
    }

    /// @inheritdoc IInterestRateModel
    function setAveragingPeriod(uint256 _averagingPeriod) external restricted {
        // settle the interval that has run so far under the window that was in force for it,
        // otherwise changing the window silently reweights time that has already passed
        _accrueAverage();
        _setAveragingPeriod(_averagingPeriod);
    }

    /// @dev Shared with {initialize} on the same grounds as {_setLiquidationBonus}. Banded at both
    /// ends because both ends are harmful in their own way: a window shorter than a handful of
    /// blocks converges on spot and gives a flash borrower their manipulation back, while a long
    /// one leaves fixed loans priced off liquidity conditions that have since moved on.
    /// @param _averagingPeriod The averaging period in seconds
    function _setAveragingPeriod(uint256 _averagingPeriod) internal {
        if (_averagingPeriod < MINIMUM_AVERAGING_PERIOD || _averagingPeriod > MAXIMUM_AVERAGING_PERIOD) {
            revert InvalidAveragingPeriod();
        }
        averagingPeriod = _averagingPeriod;
        emit SetAveragingPeriod(_averagingPeriod);
    }

    /// @inheritdoc IInterestRateModel
    function averageSupplies() public view returns (uint256 credit, uint256 supply) {
        UtilizationAverage memory average = utilizationAverage;
        uint256 weight = _averagingWeight(block.timestamp - average.lastUpdate);
        credit = _carry(average.credit, average.observedCredit, weight);
        supply = _carry(average.supply, average.observedSupply, weight);
    }

    /// @inheritdoc IInterestRateModel
    function averageUtilization() public view returns (uint256 rate) {
        (uint256 credit, uint256 supply) = averageSupplies();
        rate = _ratio(credit, supply);
    }

    /// @inheritdoc IInterestRateModel
    function averageUtilizationAfterMint(uint256 mintAmount) public view returns (uint256 rate) {
        (uint256 credit, uint256 supply) = averageSupplies();
        rate = _ratio(credit + mintAmount, supply + mintAmount);
    }

    /// @dev Update the liquidity rate based on the utilization of the stablecoin, folding the
    /// interval that has just ended into the time-weighted supplies on the way past
    function _updateLiquidityRate() internal {
        _accrueAverage();
        liquidityData.index = _index(liquidityData);
        liquidityData.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin(stablecoin).utilizationRate();
        liquidityData.ratePerYear = _nextLiquidityRate(utilization);
    }

    /// @dev Fold the observation that has stood since the last accrual into the stored averages,
    /// then record the reading that takes over from here.
    ///
    /// The stablecoin calls into this after its supplies have already moved, so the live reading is
    /// the wrong thing to credit the elapsed interval with: it has existed for zero seconds and
    /// would arrive carrying the full weight of the interval before it, which is precisely the
    /// flash manipulation the averaging exists to stop. What held over that interval is the
    /// observation taken at the previous accrual, so that is what gets folded in, and the reading
    /// arriving now is only stored — it starts earning weight from the next accrual onwards.
    ///
    /// The fold is skipped when no time has passed, so a transaction that moves the supplies
    /// several times — a premium charge splitting across tranches does — folds once and then only
    /// rolls the observation forward. That leaves the last reading of a block as the one credited
    /// with the interval that follows it, which is what weighting by time means.
    function _accrueAverage() internal {
        UtilizationAverage memory average = utilizationAverage;

        uint256 elapsed = block.timestamp - average.lastUpdate;
        if (elapsed > 0) {
            uint256 weight = _averagingWeight(elapsed);
            utilizationAverage.credit = _carry(average.credit, average.observedCredit, weight);
            utilizationAverage.supply = _carry(average.supply, average.observedSupply, weight);
            utilizationAverage.lastUpdate = block.timestamp;
        }

        (uint256 credit, uint256 supply) = IStablecoin(stablecoin).supplies();
        if (credit != average.observedCredit) utilizationAverage.observedCredit = credit;
        if (supply != average.observedSupply) utilizationAverage.observedSupply = supply;
    }

    /// @dev The share of the distance to the standing observation that an interval has earned. Zero
    /// for an interval of no length and a full ray once a whole period has run, so an observation
    /// that has only just arrived counts for nothing and one that has held out a full quiet period
    /// is taken at face value.
    /// @param elapsed The length of the interval in seconds
    /// @return weight The share, in ray decimals
    function _averagingWeight(uint256 elapsed) internal view returns (uint256 weight) {
        uint256 period = averagingPeriod;
        weight = elapsed >= period ? 1e27 : elapsed * 1e27 / period;
    }

    /// @dev Move an average a `weight` share of the way towards an observation, in either direction
    /// @param average The stored average
    /// @param observed The observation being carried towards
    /// @param weight The share of the distance to travel, in ray decimals
    /// @return carried The average carried forward
    function _carry(uint256 average, uint256 observed, uint256 weight) internal pure returns (uint256 carried) {
        carried = observed > average
            ? average + (observed - average).rayMul(weight)
            : average - (average - observed).rayMul(weight);
    }

    /// @dev Utilization as the stablecoin defines it, applied to the time-weighted supplies rather
    /// than the live ones; see {IStablecoin-utilizationRate}
    /// @param credit The credit-backed supply
    /// @param supply The total supply
    /// @return rate The utilization rate in ray decimals
    function _ratio(uint256 credit, uint256 supply) internal pure returns (uint256 rate) {
        if (supply == 0) return 0;
        rate = credit.rayDiv(supply);
    }

    /// @dev Calculate the liquidity rate based on the utilization
    function _nextLiquidityRate(uint256 utilization) internal view returns (uint256 rate) {
        Slopes memory slopes = liquiditySlopes;
        if (utilization <= slopes.kink) {
            uint256 ratio = slopes.kink == 0 ? 0 : utilization.rayDiv(slopes.kink);
            rate = slopes.base + slopes.slope0.rayMul(ratio);
        } else {
            rate = slopes.base + slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    /// @dev Calculate the cumulative index for a given index data
    /// @param data The index data to calculate the cumulative index for
    /// @return index The cumulative index
    function _index(RateData storage data) internal view returns (uint256 index) {
        index = data.index;
        if (index == 0) index = 1e27;
        if (data.lastUpdate != block.timestamp) {
            index = index.rayMul(MathUtils.calculateCompoundedInterest(data.ratePerYear, data.lastUpdate));
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
