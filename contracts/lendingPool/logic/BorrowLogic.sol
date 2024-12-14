// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVToken } from '../../../interfaces/IVToken.sol';
import { ICToken } from '../../../interfaces/ICToken.sol';
import { UserConfiguration } from '../configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { ValidationLogic } from './ValidationLogic.sol';
import { ReserveLogic } from './ReserveLogic.sol';

/// @title BorrowLogic library
/// @author kexley, inspired by Aave
/// @notice Implements the base logic for all the actions related to borrowing
library BorrowLogic {
    using ReserveLogic for DataTypes.ReserveCache;
    using ReserveLogic for DataTypes.ReserveData;
    using UserConfiguration for DataTypes.UserConfigurationMap;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

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

    /// @notice Agents can borrow assets up to their LTV value
    /// @param reservesData The state of all the reserves
    /// @param reservesList The addresses of all the active reserves
    /// @param userConfig The user configuration mapping that tracks the borrowed assets
    /// @param params The additional parameters needed to execute the borrow function
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

        (isFirstBorrowing, reserveCache.nextScaledVariableDebt) = IVToken(
            reserveCache.variableDebtTokenAddress
        ).mint(params.user, params.onBehalfOf, params.amount, reserveCache.nextVariableBorrowIndex);

        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.interestRateStrategy,
            params.asset,
            0,
            params.amount
        );

        ICToken(reserveCache.cToken).transferUnderlyingTo(params.user, params.amount);

        emit Borrow(
            params.asset,
            params.user,
            params.amount,
            reserve.currentVariableBorrowRate,
        );
    }

    /// @notice Repay an agent's debt
    /// @param reservesData The state of all the reserves
    /// @param reservesList The addresses of all the active reserves
    /// @param userConfig The user configuration mapping that tracks the borrowed assets
    /// @param params The additional parameters needed to execute the repay function
    /// @return paybackAmount The actual amount being repaid
    function executeRepay(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.UserConfigurationMap storage userConfig,
        DataTypes.ExecuteRepayParams memory params
    ) external returns (uint256 paybackAmount) {
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

        paybackAmount = variableDebt;

        if (params.amount < paybackAmount) {
            paybackAmount = params.amount;
        }

        reserveCache.nextScaledVariableDebt = IVariableDebtToken(
            reserveCache.variableDebtTokenAddress
        ).burn(params.onBehalfOf, paybackAmount, reserveCache.nextVariableBorrowIndex);

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.interestRateStrategy,
            params.asset,
            paybackAmount,
            0
        );

        if (variableDebt - paybackAmount == 0) {
            userConfig.setBorrowing(reserve.id, false);
        }

        IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aTokenAddress, paybackAmount);

        emit Repay(params.asset, params.onBehalfOf, msg.sender, paybackAmount);
    }
}