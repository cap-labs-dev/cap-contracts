// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {MathUtils} from '../math/MathUtils.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {Errors} from '../helpers/Errors.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title ReserveLogic library
 * @author Aave
 * @notice Implements the logic to update the reserves state
 */
library ReserveLogic {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeCast for uint256;
    using ReserveLogic for DataTypes.ReserveData;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    // See `IPool` for descriptions
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 variableBorrowRate,
        uint256 variableBorrowIndex
    );

    /**
    * @notice Returns the ongoing normalized variable debt for the reserve.
    * @dev A value of 1e27 means there is no debt. As time passes, the debt is accrued
    * @dev A value of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
    * @param reserve The reserve object
    * @return The normalized variable debt, expressed in ray
    */
    function getNormalizedDebt(
        DataTypes.ReserveData storage reserve
    ) internal view returns (uint256) {
        uint40 timestamp = reserve.lastUpdateTimestamp;

        if (timestamp == block.timestamp) {
        //if the index was updated in the same block, no need to perform any calculation
            return reserve.variableBorrowIndex;
        } else {
            return
                MathUtils.calculateCompoundedInterest(reserve.currentVariableBorrowRate, timestamp)
                    .rayMul(reserve.variableBorrowIndex);
        }
    }

    /**
    * @notice Updates the liquidity cumulative index and the variable borrow index.
    * @param reserve The reserve object
    * @param reserveCache The caching layer for the reserve data
    */
    function updateState(
        DataTypes.ReserveData storage reserve,
        DataTypes.ReserveCache memory reserveCache
    ) internal {
        // If time didn't pass since last stored timestamp, skip state update
        if (reserve.lastUpdateTimestamp == uint40(block.timestamp)) {
            return;
        }

        _updateIndexes(reserve, reserveCache);
        _accrueToTreasury(reserve, reserveCache);

        reserve.lastUpdateTimestamp = uint40(block.timestamp);
    }

    /**
    * @notice Initializes a reserve.
    * @param reserve The reserve object
    * @param cToken The address of the overlying atoken contract
    * @param vToken The address of the overlying variable debt token contract
    */
    function init(
        DataTypes.ReserveData storage reserve,
        address cToken,
        address vToken
    ) internal {
        require(reserve.cToken == address(0), Errors.RESERVE_ALREADY_INITIALIZED);

        reserve.variableBorrowIndex = uint128(WadRayMath.RAY);
        reserve.cToken = cToken;
        reserve.vToken = vToken;
    }

    /**
    * @notice Updates the reserve current variable borrow rate and the current liquidity rate.
    * @param reserve The reserve reserve to be updated
    * @param reserveCache The caching layer for the reserve data
    * @param reserveAddress The address of the reserve to be updated
    * @param liquidityAdded The amount of liquidity added to the protocol (supply or repay) in the previous action
    * @param liquidityTaken The amount of liquidity taken from the protocol (redeem or borrow)
    */
    function updateInterestRatesAndBalance(
        DataTypes.ReserveData storage reserve,
        DataTypes.ReserveCache memory reserveCache,
        address interestRateStrategy,
        address reserveAddress,
        uint256 liquidityAdded,
        uint256 liquidityTaken
    ) internal {
        uint256 totalVariableDebt = reserveCache.nextScaledVariableDebt.rayMul(
            reserveCache.nextVariableBorrowIndex
        );

        (uint256 nextVariableRate) = IReserveInterestRateStrategy(
            interestRateStrategyAddress
        ).calculateInterestRates(
            DataTypes.CalculateInterestRatesParams({
                liquidityAdded: liquidityAdded,
                liquidityTaken: liquidityTaken,
                totalDebt: totalVariableDebt,
                reserve: reserveAddress,
                underlyingBalance: reserve.underlyingBalance
            })
        );

        reserve.currentVariableBorrowRate = nextVariableRate.toUint128();

        if (liquidityAdded > 0) {
            reserve.underlyingBalance += liquidityAdded.toUint128();
        }
        if (liquidityTaken > 0) {
            reserve.underlyingBalance -= liquidityTaken.toUint128();
        }

        emit ReserveDataUpdated(
            reserveAddress,
            nextVariableRate,
            reserveCache.nextVariableBorrowIndex
        );
    }

    /**
    * @notice Mints part of the repaid interest to the reserve treasury as a function of the reserve factor for the
    * specific asset.
    * @param reserve The reserve to be updated
    * @param reserveCache The caching layer for the reserve data
    */
    function _accrueToTreasury(
        DataTypes.ReserveData storage reserve,
        DataTypes.ReserveCache memory reserveCache
    ) internal {
        //calculate the total variable debt at moment of the last interaction
        uint256 prevTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
            reserveCache.currVariableBorrowIndex
        );

        //calculate the new total variable debt after accumulation of the interest on the index
        uint256 currTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
            reserveCache.nextVariableBorrowIndex
        );

        //debt accrued is the sum of the current debt minus the sum of the debt at the last update
        uint256 totalDebtAccrued = currTotalVariableDebt - prevTotalVariableDebt;

        uint256 amountToMint = totalDebtAccrued;

        if (amountToMint != 0) {
            reserve.accruedToTreasury += amountToMint.toUint128();
        }
    }

    /**
    * @notice Updates the reserve indexes and the timestamp of the update.
    * @param reserve The reserve reserve to be updated
    * @param reserveCache The cache layer holding the cached protocol data
    */
    function _updateIndexes(
        DataTypes.ReserveData storage reserve,
        DataTypes.ReserveCache memory reserveCache
    ) internal {
        // Variable borrow index only gets updated if there is any variable debt.
        // reserveCache.currVariableBorrowRate != 0 is not a correct validation,
        // because a positive base variable rate can be stored on
        // reserveCache.currVariableBorrowRate, but the index should not increase
        if (reserveCache.currScaledVariableDebt != 0) {
            uint256 cumulatedVariableBorrowInterest = MathUtils.calculateCompoundedInterest(
                reserveCache.currVariableBorrowRate,
                reserveCache.reserveLastUpdateTimestamp
            );
            reserveCache.nextVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(
                reserveCache.currVariableBorrowIndex
            );
            reserve.variableBorrowIndex = reserveCache.nextVariableBorrowIndex.toUint128();
        }
    }

    /**
    * @notice Creates a cache object to avoid repeated storage reads and external contract calls when updating state and
    * interest rates.
    * @param reserve The reserve object for which the cache will be filled
    * @return reserveCache The cache object
    */
    function cache(
        DataTypes.ReserveData storage reserve
    ) internal view returns (DataTypes.ReserveCache memory reserveCache) {
        reserveCache.reserveConfiguration = reserve.configuration;
        reserveCache.currVariableBorrowIndex = reserveCache.nextVariableBorrowIndex = reserve
        .variableBorrowIndex;
        reserveCache.currVariableBorrowRate = reserve.currentVariableBorrowRate;

        reserveCache.cToken = reserve.aToken;
        reserveCache.vToken = reserve.vToken;

        reserveCache.reserveLastUpdateTimestamp = reserve.lastUpdateTimestamp;

        reserveCache.currScaledVariableDebt = reserveCache.nextScaledVariableDebt = IVariableDebtToken(
            reserveCache.vToken
        ).scaledTotalSupply();
    }
}