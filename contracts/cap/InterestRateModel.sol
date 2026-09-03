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
        uint256 _liquidationBonus
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
        _setLiquidationBonus(_liquidationBonus);
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
    function liquidityRate(uint256 termUtilization) public view returns (uint256 rate) {
        rate = liquidityRate().rayMul(termMultiplier(termUtilization));
    }

    /// @inheritdoc IInterestRateModel
    function fixedRates(address market, uint256 termUtilization)
        public
        view
        returns (uint256 liquidity, uint256 underwriter)
    {
        liquidity = liquidityRate(termUtilization).rayMul(marketMultiplier(market));
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

    /// @dev Update the liquidity rate based on the utilization of the stablecoin
    function _updateLiquidityRate() internal {
        liquidityData.index = _index(liquidityData);
        liquidityData.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin(stablecoin).utilizationRate();
        liquidityData.ratePerYear = _nextLiquidityRate(utilization);
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
