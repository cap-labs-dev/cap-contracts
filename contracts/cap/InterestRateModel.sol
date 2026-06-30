// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
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
    /// @param _authority The address of the authority
    function initialize(address _stablecoin, address _authority) external initializer {
        __AccessManaged_init(_authority);
        IInterestRateModel.InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.stablecoin = _stablecoin;
        $.variableIndex = 1e27;
        $.fixedIndex = 1e27;
        $.lastUpdate = block.timestamp;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Setter functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Set the variable slopes for the InterestRateModel
    /// @param _slopes The new variable slopes
    function setVariableSlopes(Slopes memory _slopes) external restricted {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.variableSlopes = _slopes;
        _update();
        emit SetVariableSlopes(_slopes);
    }

    /// @notice Set the fixed slopes for the InterestRateModel
    /// @param _slopes The new fixed slopes
    function setFixedSlopes(Slopes memory _slopes) external restricted {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.fixedSlopes = _slopes;
        _update();
        emit SetFixedSlopes(_slopes);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Index functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update interest rates based on the utilization of the stablecoin
    function update() external {
        _update();
    }

    /// @notice Get the current variable index
    /// @return currentIndex The current variable index
    function variableIndex() public view returns (uint256 currentIndex) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();

        currentIndex = $.variableIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.variableRate, $.lastUpdate));
        }
    }

    /// @notice Get the current fixed index
    /// @return currentIndex The current fixed index
    function fixedIndex() public view returns (uint256 currentIndex) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();

        currentIndex = $.fixedIndex;
        if ($.lastUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.fixedRate, $.lastUpdate));
        }
    }

    /// @dev Update the indexes and then the interest rates
    function _update() internal {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        $.variableIndex = variableIndex();
        $.fixedIndex = fixedIndex();
        $.lastUpdate = block.timestamp;
        uint256 utilization = IStablecoin($.stablecoin).utilizationRate();
        $.variableRate = _nextInterestRate(utilization, $.variableSlopes);
        $.fixedRate = _nextInterestRate(utilization, $.fixedSlopes);
    }

    /// @dev Calculate the next interest rate based on the utilization and slopes
    /// @param utilization The utilization of the stablecoin
    /// @param slopes The slopes to use for the interest rate
    /// @return rate The next interest rate
    function _nextInterestRate(uint256 utilization, Slopes memory slopes) internal view returns (uint256 rate) {
        if (utilization <= slopes.kink) {
            rate = slopes.base + slopes.slope0.rayMul(utilization.rayDiv(slopes.kink));
        } else {
            rate = slopes.base + slopes.slope0
                + slopes.slope1.rayMul((utilization - slopes.kink).rayDiv(1e27 - slopes.kink));
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Rate functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Get the current variable rate
    /// @return rate The current variable rate
    function variableRate() public view returns (uint256 rate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        rate = $.variableRate;
    }

    /// @notice Get the current fixed rate
    /// @return rate The current fixed rate
    function fixedRate() public view returns (uint256 rate) {
        InterestRateModelStorage storage $ = getInterestRateModelStorage();
        rate = $.fixedRate;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
