// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IInverseInterestRateModel } from "../interfaces/IInverseInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { InverseInterestRateModelStorageUtils } from "../storage/InverseInterestRateModelStorageUtils.sol";
import { MathUtils } from "../utils/MathUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title InverseInterestRateModel
/// @author kexley
/// @notice The InverseInterestRateModel calculates the inverse of the interest rates for utilization of underwriter credit.
contract InverseInterestRateModel is
    IInverseInterestRateModel,
    UUPSUpgradeable,
    AccessManagedUpgradeable,
    InverseInterestRateModelStorageUtils
{
    using WadRayMath for uint256;

    /// @notice Initialize the InverseInterestRateModel
    /// @param _authority The address of the authority
    /// @param _lender The address of the lender
    function initialize(address _authority, address _lender) external initializer {
        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();
        $.lender = _lender;
        __AccessManaged_init(_authority);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Setter functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Set the slopes for the InverseInterestRateModel
    /// @param _slopes The new fixed slopes
    function setSlopes(bytes32 marketId, IInterestRateModel.Slopes memory _slopes) external restricted {
        if (_slopes.base < _slopes.slope0) revert InvalidSlopes();
        if (_slopes.kink == 0 || _slopes.kink >= 1e27) revert InvalidSlopes();

        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();
        $.slopes[marketId] = _slopes;
        if ($.index[marketId] == 0) $.index[marketId] = 1e27;
        _update(marketId);
        emit SetSlopes(marketId, _slopes);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Index functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update interest rates based on the utilization of the market
    function update(bytes32 marketId) external {
        _update(marketId);
    }

    /// @notice Get the current index
    /// @return currentIndex The current index
    function index(bytes32 marketId) public view returns (uint256 currentIndex) {
        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();

        currentIndex = $.index[marketId];
        if ($.lastUpdate[marketId] != block.timestamp) {
            currentIndex =
                currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.rate[marketId], $.lastUpdate[marketId]));
        }
    }

    /// @dev Update the indexes and then the interest rates based on the utilization of the market
    /// @param marketId The market to update
    function _update(bytes32 marketId) internal {
        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();
        $.index[marketId] = index(marketId);
        $.lastUpdate[marketId] = block.timestamp;
        $.rate[marketId] = nextInterestRate(marketId);
    }

    /// @dev Calculate the next interest rate based on the utilization and slopes
    /// @param slopes The slopes to use
    /// @param utilization The utilization of the market
    /// @return newRate The next interest rate
    function _calculateInterestRate(IInterestRateModel.Slopes memory slopes, uint256 utilization)
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

    /// @notice Get the current interest rate
    /// @param marketId The ID of the market
    /// @return currentRate The current interest rate
    function rate(bytes32 marketId) external view returns (uint256 currentRate) {
        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();
        currentRate = $.rate[marketId];
    }

    /// @notice Get the next interest rate based on the utilization of the market
    /// @param marketId The ID of the market
    /// @return nextRate The next interest rate
    function nextInterestRate(bytes32 marketId) public view returns (uint256 nextRate) {
        IInverseInterestRateModel.InverseInterestRateModelStorage storage $ = getInverseInterestRateModelStorage();
        uint256 utilization = ILender($.lender).utilization(marketId);
        nextRate = _calculateInterestRate($.slopes[marketId], utilization);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
