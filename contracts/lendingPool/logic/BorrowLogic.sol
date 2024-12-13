// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {ReserveLogic} from './ReserveLogic.sol';

/**
 * @title BorrowLogic library
 * @author Aave
 * @notice Implements the base logic for all the actions related to borrowing
 */
library BorrowLogic {
    using ReserveLogic for DataTypes.ReserveCache;
    using ReserveLogic for DataTypes.ReserveData;
    using GPv2SafeERC20 for IERC20;
    using UserConfiguration for DataTypes.UserConfigurationMap;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using SafeCast for uint256;

    // See `IPool` for descriptions
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 borrowRate
    );
    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256 amount,
    );

    /**
    * @notice Implements the borrow feature. Borrowing allows users that provided collateral to draw liquidity from the
    * Aave protocol proportionally to their collateralization power. For isolated positions, it also increases the
    * isolated debt.
    * @dev  Emits the `Borrow()` event
    * @param reservesData The state of all the reserves
    * @param reservesList The addresses of all the active reserves
    * @param eModeCategories The configuration of all the efficiency mode categories
    * @param userConfig The user configuration mapping that tracks the supplied/borrowed assets
    * @param params The additional parameters needed to execute the borrow function
    */
    function executeBorrow(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.UserConfigurationMap storage userConfig,
        DataTypes.ExecuteBorrowParams memory params
    ) external {
        DataTypes.ReserveData storage reserve = reservesData[params.asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);

        ValidationLogic.validateBorrow(
            reservesData,
            reservesList,
            DataTypes.ValidateBorrowParams({
                reserveCache: reserveCache,
                userConfig: userConfig,
                asset: params.asset,
                userAddress: params.onBehalfOf,
                amount: params.amount,
                reservesCount: params.reservesCount,
                oracle: params.oracle,
                priceOracleSentinel: params.priceOracleSentinel,
                avs: params.avs
            })
        );

        bool isFirstBorrowing = false;

        (isFirstBorrowing, reserveCache.nextScaledVariableDebt) = IVariableDebtToken(
            reserveCache.variableDebtTokenAddress
        ).mint(params.user, params.amount, reserveCache.nextVariableBorrowIndex);

        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.asset,
            0,
            params.amount
        );

        IAToken(reserveCache.aTokenAddress).transferUnderlyingTo(params.user, params.amount);

        emit Borrow(
            params.asset,
            params.user,
            params.amount,
            reserve.currentVariableBorrowRate,
        );
    }

    /**
    * @notice Implements the repay feature. Repaying transfers the underlying back to the aToken and clears the
    * equivalent amount of debt for the user by burning the corresponding debt token. For isolated positions, it also
    * reduces the isolated debt.
    * @dev  Emits the `Repay()` event
    * @param reservesData The state of all the reserves
    * @param reservesList The addresses of all the active reserves
    * @param userConfig The user configuration mapping that tracks the supplied/borrowed assets
    * @param params The additional parameters needed to execute the repay function
    * @return The actual amount being repaid
    */
    function executeRepay(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.UserConfigurationMap storage userConfig,
        DataTypes.ExecuteRepayParams memory params
    ) external returns (uint256) {
        DataTypes.ReserveData storage reserve = reservesData[params.asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();
        reserve.updateState(reserveCache);

        uint256 variableDebt = IERC20(reserveCache.variableDebtTokenAddress).balanceOf(
            params.onBehalfOf
        );

        ValidationLogic.validateRepay(
            reserveCache,
            params.amount,
            params.onBehalfOf,
            variableDebt
        );

        uint256 paybackAmount = variableDebt;

        if (params.amount < paybackAmount) {
            paybackAmount = params.amount;
        }

        reserveCache.nextScaledVariableDebt = IVariableDebtToken(
            reserveCache.variableDebtTokenAddress
        ).burn(params.onBehalfOf, paybackAmount, reserveCache.nextVariableBorrowIndex);

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.asset,
            paybackAmount,
            0
        );

        if (variableDebt - paybackAmount == 0) {
            userConfig.setBorrowing(reserve.id, false);
        }

        IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aTokenAddress, paybackAmount);

        IAToken(reserveCache.aTokenAddress).handleRepayment(
            msg.sender,
            params.onBehalfOf,
            paybackAmount
        );

        emit Repay(params.asset, params.onBehalfOf, msg.sender, paybackAmount);

        return paybackAmount;
    }
}