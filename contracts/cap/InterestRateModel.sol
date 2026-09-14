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
/// @notice Variable and fixed interest rates for the stablecoin
contract InterestRateModel layout at erc7201("cap.storage.InterestRateModel")
    is
    IInterestRateModel,
    AccessManagedUpgradeable,
    UUPSUpgradeable
{
    using WadRayMath for uint256;

    /// @inheritdoc IInterestRateModel
    address public stablecoin;

    /// @inheritdoc IInterestRateModel
    Slopes public liquiditySlopes;

    /// @inheritdoc IInterestRateModel
    uint256 public termMultiplierSlope;

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
    uint256 public retentionPerSecond;

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
        // the multiplier band has no setter, so an inverted one would leave every
        // {IBaseMarket-setMarketMultiplier} permanently unsatisfiable with no way to repair it
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
    function liquidityIndex() public view returns (uint256 index) {
        index = _index(liquidityData);
    }

    /// @inheritdoc IInterestRateModel
    function setTermMultiplierSlope(uint256 _slope) external restricted {
        termMultiplierSlope = _slope;
        emit SetTermMultiplierSlope(_slope);
    }

    /// @inheritdoc IInterestRateModel
    /// @dev Uses the time-weighted utilization, not {liquidityRate}. See {averageUtilizationAfterMint}.
    function fixedRatesAfterMint(address market, uint256 termUtilization, uint256 mintAmount)
        public
        view
        returns (uint256 liquidity, uint256 underwriter)
    {
        liquidity = _nextLiquidityRate(averageUtilizationAfterMint(mintAmount)).rayMul(termMultiplier(termUtilization));
        underwriter = underwriterRate(market);
    }

    /// @inheritdoc IInterestRateModel
    function termMultiplier(uint256 termUtilization) public view returns (uint256 multiplier) {
        // at or beyond the maximum term, pay the plain liquidity rate
        if (termUtilization >= 1e27) return 1e27;
        multiplier = 1e27 + termMultiplierSlope.rayMul(1e27 - termUtilization);
    }

    /// @inheritdoc IInterestRateModel
    function setLiquidationBonus(uint256 _liquidationBonus) external restricted {
        _setLiquidationBonus(_liquidationBonus);
    }

    /// @dev Shared with {initialize}. Same bounds as the setter.
    /// @param _liquidationBonus The liquidation bonus in ray decimals
    function _setLiquidationBonus(uint256 _liquidationBonus) internal {
        if (_liquidationBonus > 0.1e27) revert InvalidLiquidationBonus();
        liquidationBonus = _liquidationBonus;
        emit SetLiquidationBonus(_liquidationBonus);
    }

    /// @inheritdoc IInterestRateModel
    function setAveragingPeriod(uint256 _averagingPeriod) external restricted {
        // settle the running interval under the old window first
        _accrueAverage();
        _setAveragingPeriod(_averagingPeriod);
    }

    /// @dev Shared with {initialize}. Banded at both ends.
    /// @param _averagingPeriod The averaging period in seconds
    function _setAveragingPeriod(uint256 _averagingPeriod) internal {
        if (_averagingPeriod < MINIMUM_AVERAGING_PERIOD || _averagingPeriod > MAXIMUM_AVERAGING_PERIOD) {
            revert InvalidAveragingPeriod();
        }
        averagingPeriod = _averagingPeriod;
        // per-second retention; residual after one window is ~1/e
        retentionPerSecond = 1e27 - 1e27 / _averagingPeriod;
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
    function unsmoothedCredit() public view returns (uint256 amount) {
        (uint256 credit,) = averageSupplies();
        (uint256 liveCredit,) = IStablecoin(stablecoin).supplies();
        if (liveCredit > credit) amount = liveCredit - credit;
    }

    /// @inheritdoc IInterestRateModel
    function averageUtilizationAfterMint(uint256 mintAmount) public view returns (uint256 rate) {
        (uint256 credit, uint256 supply) = averageSupplies();
        // Credit already minted but not yet absorbed into the average (a same-block borrow, or
        // the residual of a recent one) is added to both sides. Reserve-only moves do not appear
        // in the credit gap, so a flash deposit still cannot suppress the price.
        (uint256 liveCredit,) = IStablecoin(stablecoin).supplies();
        if (liveCredit > credit) {
            uint256 extra = liveCredit - credit;
            credit += extra;
            supply += extra;
        }
        rate = _ratio(credit + mintAmount, supply + mintAmount);
    }

    /// @dev Accrue the averages, then set the liquidity rate from live utilization.
    function _updateLiquidityRate() internal {
        _accrueAverage();
        liquidityData.index = _index(liquidityData);
        liquidityData.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin(stablecoin).utilizationRate();
        liquidityData.ratePerYear = _nextLiquidityRate(utilization);
    }

    /// @dev Fold the prior observation into the averages, then store the live reading.
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

    /// @dev Share of the distance to the observation earned over `elapsed`. Compounds.
    /// @param elapsed Seconds since the last fold
    /// @return weight Share in ray decimals
    function _averagingWeight(uint256 elapsed) internal view returns (uint256 weight) {
        weight = 1e27 - retentionPerSecond.rayPow(elapsed);
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

    /// @dev Utilization as the stablecoin defines it, on the given supplies.
    /// @param credit The credit-backed supply
    /// @param supply The total supply
    /// @return rate The utilization rate in ray decimals
    function _ratio(uint256 credit, uint256 supply) internal pure returns (uint256 rate) {
        if (supply == 0) return 0;
        rate = credit.rayDiv(supply);
    }

    /// @dev Calculate the liquidity rate based on the utilization
    /// @param utilization The utilization rate in ray decimals
    /// @return rate The liquidity rate per year in ray decimals
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
