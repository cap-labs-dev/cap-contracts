// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMarket } from "../interfaces/IMarket.sol";
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
    /// @param _authority The address of the authority
    /// @param _stablecoin The address of the Stablecoin token
    function initialize(address _authority, address _stablecoin) external initializer {
        __AccessManaged_init(_authority);
        Storage storage $ = getInterestRateModelStorage();
        $.stablecoin = _stablecoin;
        $.variableIndex = 1e27;
        $.fixedIndex = 1e27;
        $.lastUpdate = block.timestamp;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Stablecoin functions **************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update the supply interest rates based on the utilization of the stablecoin
    function update() external {
        _update();
    }

    /// @notice Set the variable slopes for the supply interest rate
    function setVariableSlopes(Slopes memory _slopes) external restricted {
        Storage storage $ = getInterestRateModelStorage();
        $.variableSlopes = _slopes;
        _update();
        emit SetVariableSlopes(_slopes);
    }

    /// @notice Set the fixed slopes for the supply interest rate
    function setFixedSlopes(Slopes memory _slopes) external restricted {
        Storage storage $ = getInterestRateModelStorage();
        $.fixedSlopes = _slopes;
        _update();
        emit SetFixedSlopes(_slopes);
    }

    /// @notice Get the current variable supply index
    /// @return currentIndex The current variable index
    function variableIndex() public view returns (uint256 currentIndex) {
        Storage storage $ = getInterestRateModelStorage();

        currentIndex = $.variableIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.variableRate, $.lastUpdate));
        }
    }

    /// @notice Get the current fixed supply index
    /// @return currentIndex The current fixed index
    function fixedIndex() public view returns (uint256 currentIndex) {
        Storage storage $ = getInterestRateModelStorage();

        currentIndex = $.fixedIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.fixedRate, $.lastUpdate));
        }
    }

    /// @notice Get the current variable supply rate
    /// @return rate The current variable rate
    function variableRate() public view returns (uint256 rate) {
        Storage storage $ = getInterestRateModelStorage();
        rate = $.variableRate;
    }

    /// @notice Get the current fixed supply rate
    /// @return rate The current fixed rate
    function fixedRate() public view returns (uint256 rate) {
        Storage storage $ = getInterestRateModelStorage();
        rate = $.fixedRate;
    }

    /// @dev Update the supply indexes and then the supply interest rates
    function _update() internal {
        Storage storage $ = getInterestRateModelStorage();
        $.variableIndex = variableIndex();
        $.fixedIndex = fixedIndex();
        $.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin($.stablecoin).utilizationRate();
        $.variableRate = _nextInterestRate(utilization, $.variableSlopes);
        $.fixedRate = _nextInterestRate(utilization, $.fixedSlopes);
    }

    /// @dev Calculate the next supply interest rate based on the utilization and slopes
    /// @param utilization The utilization of the stablecoin
    /// @param slopes The slopes to use for the interest rate
    /// @return rate The next interest rate
    function _nextInterestRate(uint256 utilization, Slopes memory slopes) internal pure returns (uint256 rate) {
        if (utilization <= slopes.kink) {
            // unconfigured slopes (kink == 0) accrue no rate rather than dividing by zero
            uint256 ratio = slopes.kink == 0 ? 0 : utilization.rayDiv(slopes.kink);
            rate = slopes.base + slopes.slope0.rayMul(ratio);
        } else {
            rate = slopes.base + slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Market functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update a market's inverse premium rate based on the utilization of the market
    /// @param market The market to update
    function update(address market) external {
        _updateMarket(market);
    }

    /// @notice Set the slopes for a market's inverse premium rate
    function setUnderwriterSlopes(address market, Slopes memory _slopes) external restricted {
        if (_slopes.base < _slopes.slope0) revert InvalidSlopes();
        if (_slopes.kink == 0 || _slopes.kink >= 1e27) revert InvalidSlopes();

        Storage storage $ = getInterestRateModelStorage();
        $.underwriterSlopes[market] = _slopes;
        if ($.underwriterIndex[market] == 0) $.underwriterIndex[market] = 1e27;
        _updateMarket(market);
        emit SetUnderwriterSlopes(market, _slopes);
    }

    /// @notice Get the current inverse premium index for a market
    /// @param market The market to get the current index for
    /// @return currentIndex The current index
    function underwriterIndex(address market) public view returns (uint256 currentIndex) {
        Storage storage $ = getInterestRateModelStorage();

        currentIndex = $.underwriterIndex[market];
        if ($.lastUnderwriterUpdate[market] != block.timestamp) {
            currentIndex = currentIndex.rayMul(
                MathUtils.calculateCompoundedInterest($.underwriterRate[market], $.lastUnderwriterUpdate[market])
            );
        }
    }

    /// @notice Get the current inverse premium rate for a market
    /// @param market The market to get the current interest rate for
    /// @return currentRate The current interest rate
    function underwriterRate(address market) external view returns (uint256 currentRate) {
        Storage storage $ = getInterestRateModelStorage();
        currentRate = $.underwriterRate[market];
    }

    /// @notice Get the next inverse premium rate based on the utilization of the market
    /// @param market The market to get the next interest rate for
    /// @return nextRate The next interest rate
    function nextInterestRate(address market) public view returns (uint256 nextRate) {
        Storage storage $ = getInterestRateModelStorage();
        uint256 utilization = IMarket(market).utilization();
        nextRate = _calculateInverseRate($.underwriterSlopes[market], utilization);
    }

    /// @dev Update a market's inverse index and then the inverse interest rate
    /// @param market The market to update
    function _updateMarket(address market) internal {
        Storage storage $ = getInterestRateModelStorage();
        $.underwriterIndex[market] = underwriterIndex(market);
        $.lastUnderwriterUpdate[market] = block.timestamp;
        $.underwriterRate[market] = nextInterestRate(market);
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
            uint256 ratio = slopes.kink == 0 ? 0 : utilization.rayDiv(slopes.kink);
            newRate = slopes.base - slopes.slope0.rayMul(ratio);
        } else {
            newRate = slopes.base - slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
