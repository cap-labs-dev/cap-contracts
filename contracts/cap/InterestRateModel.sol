// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { InterestRateModelStorageUtils } from "../storage/InterestRateModelStorageUtils.sol";
import { MathUtils } from "../utils/MathUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title InterestRateModel
/// @author kexley
/// @notice The InterestRateModel calculates the canonical variable and fixed interest rates for Stablecoin.
contract InterestRateModel is
    IInterestRateModel,
    UUPSUpgradeable,
    AccessManagedUpgradeable,
    InterestRateModelStorageUtils
{
    using WadRayMath for uint256;

    /// @notice Initialize the InterestRateModel
    /// @param _stablecoin The address of the Stablecoin token
    /// @param _lender The address of the Lender
    /// @param _authority The address of the authority
    function initialize(address _stablecoin, address _lender, address _authority) external initializer {
        __AccessManaged_init(_authority);
        IInterestRateModel.InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.stablecoin = _stablecoin;
        $.variableIndex = 1e27;
        $.fixedIndex = 1e27;
        $.lastUpdate = block.timestamp;
        $.lender = _lender;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Setter functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Set the variable slopes for the supply interest rate
    /// @param _slopes The new variable slopes
    function setVariableSlopes(Slopes memory _slopes) external restricted {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.variableSlopes = _slopes;
        _update();
        emit SetVariableSlopes(_slopes);
    }

    /// @notice Set the fixed slopes for the supply interest rate
    /// @param _slopes The new fixed slopes
    function setFixedSlopes(Slopes memory _slopes) external restricted {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.fixedSlopes = _slopes;
        _update();
        emit SetFixedSlopes(_slopes);
    }

    /// @notice Set the slopes for a market's inverse premium rate
    /// @param marketId The ID of the market
    /// @param _slopes The new inverse slopes
    function setMarketSlopes(bytes32 marketId, Slopes memory _slopes) external restricted {
        if (_slopes.base < _slopes.slope0) revert InvalidSlopes();
        if (_slopes.kink == 0 || _slopes.kink >= 1e27) revert InvalidSlopes();

        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.marketSlopes[marketId] = _slopes;
        if ($.marketIndex[marketId] == 0) $.marketIndex[marketId] = 1e27;
        _updateMarket(marketId);
        emit SetMarketSlopes(marketId, _slopes);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Index functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update the supply interest rates based on the utilization of the stablecoin
    function update() external {
        _update();
    }

    /// @notice Update a market's inverse premium rate based on the utilization of the market
    /// @param marketId The market to update
    function update(bytes32 marketId) external {
        _updateMarket(marketId);
    }

    /// @notice Get the current variable supply index
    /// @return currentIndex The current variable index
    function variableIndex() public view returns (uint256 currentIndex) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();

        currentIndex = $.variableIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.variableRate, $.lastUpdate));
        }
    }

    /// @notice Get the current fixed supply index
    /// @return currentIndex The current fixed index
    function fixedIndex() public view returns (uint256 currentIndex) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();

        currentIndex = $.fixedIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.fixedRate, $.lastUpdate));
        }
    }

    /// @notice Get the current inverse premium index for a market
    /// @param marketId The ID of the market
    /// @return currentIndex The current index
    function index(bytes32 marketId) public view returns (uint256 currentIndex) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();

        currentIndex = $.marketIndex[marketId];
        if ($.lastMarketUpdate[marketId] != block.timestamp) {
            currentIndex = currentIndex.rayMul(
                MathUtils.calculateCompoundedInterest($.marketRate[marketId], $.lastMarketUpdate[marketId])
            );
        }
    }

    /// @dev Update the supply indexes and then the supply interest rates
    function _update() internal {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.variableIndex = variableIndex();
        $.fixedIndex = fixedIndex();
        $.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin($.stablecoin).utilizationRate();
        $.variableRate = _nextInterestRate(utilization, $.variableSlopes);
        $.fixedRate = _nextInterestRate(utilization, $.fixedSlopes);
    }

    /// @dev Update a market's inverse index and then the inverse interest rate
    /// @param marketId The market to update
    function _updateMarket(bytes32 marketId) internal {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.marketIndex[marketId] = index(marketId);
        $.lastMarketUpdate[marketId] = block.timestamp;
        $.marketRate[marketId] = nextInterestRate(marketId);
    }

    /// @dev Calculate the next supply interest rate based on the utilization and slopes
    /// @param utilization The utilization of the stablecoin
    /// @param slopes The slopes to use for the interest rate
    /// @return rate The next interest rate
    function _nextInterestRate(uint256 utilization, Slopes memory slopes) internal pure returns (uint256 rate) {
        if (utilization <= slopes.kink) {
            rate = slopes.base + slopes.slope0.rayMul(utilization.rayDiv(slopes.kink));
        } else {
            rate = slopes.base + slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    /// @dev Calculate the next inverse interest rate based on the utilization and slopes
    /// @param slopes The slopes to use
    /// @param utilization The utilization of the market
    /// @return newRate The next interest rate
    function _calculateInverseRate(IInterestRateModel.Slopes memory slopes, uint256 utilization)
        internal
        pure
        returns (uint256 newRate)
    {
        if (utilization <= slopes.kink) {
            newRate = slopes.base - slopes.slope0.rayMul(utilization.rayDiv(slopes.kink));
        } else {
            newRate = slopes.base - slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Rate functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Get the current variable supply rate
    /// @return rate The current variable rate
    function variableRate() public view returns (uint256 rate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        rate = $.variableRate;
    }

    /// @notice Get the current fixed supply rate
    /// @return rate The current fixed rate
    function fixedRate() public view returns (uint256 rate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        rate = $.fixedRate;
    }

    /// @notice Get the current inverse premium rate for a market
    /// @param marketId The ID of the market
    /// @return currentRate The current interest rate
    function rate(bytes32 marketId) external view returns (uint256 currentRate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        currentRate = $.marketRate[marketId];
    }

    /// @notice Get the next inverse premium rate based on the utilization of the market
    /// @param marketId The ID of the market
    /// @return nextRate The next interest rate
    function nextInterestRate(bytes32 marketId) public view returns (uint256 nextRate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        uint256 utilization = ILender($.lender).utilization(marketId);
        nextRate = _calculateInverseRate($.marketSlopes[marketId], utilization);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
