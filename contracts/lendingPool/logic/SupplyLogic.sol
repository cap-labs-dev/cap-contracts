// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAToken } from '../../../interfaces/IAToken.sol';
import { Errors } from '../helpers/Errors.sol';
import { ValidationLogic } from './ValidationLogic.sol';
import { ReserveLogic } from './ReserveLogic.sol';

library SupplyLogic {
    using ReserveLogic for DataTypes.ReserveCache;
    using ReserveLogic for DataTypes.ReserveData;

    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);
    event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount);

    /// @notice Deposit an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amount Amount of asset to deposit
    function executeSupply(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        DataTypes.ExecuteSupplyParams memory params
    ) external {
        DataTypes.ReserveData storage reserve = reservesData[params.asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);

        ValidationLogic.validateSupply(reserveCache, reserve, params.amount, params.onBehalfOf);

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.interestRateStrategy,
            params.asset,
            params.amount,
            0
        );

        IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aTokenAddress, params.amount);

        IAToken(reserveCache.aTokenAddress).mint(
            msg.sender,
            params.onBehalfOf,
            params.amount
        );

        emit Supply(params.asset, msg.sender, params.onBehalfOf, params.amount);
    }

    function executeWithdraw(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        DataTypes.ExecuteWithdrawParams memory params
    ) external returns (uint256) {
        DataTypes.ReserveData storage reserve = reservesData[params.asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        require(params.to != reserveCache.aTokenAddress, Errors.WITHDRAW_TO_ATOKEN);

        reserve.updateState(reserveCache);

        uint256 userBalance = IAToken(reserveCache.aTokenAddress).balanceOf(msg.sender);
        uint256 amountToWithdraw = params.amount;

        if (params.amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        ValidationLogic.validateWithdraw(reserveCache, amountToWithdraw, userBalance);

        reserve.updateInterestRatesAndBalance(
            reserveCache,
            params.interestRateStrategy,
            params.asset,
            0,
            amountToWithdraw
        );

        IAToken(reserveCache.aTokenAddress).burn(
            msg.sender,
            params.to,
            amountToWithdraw
        );

        emit Withdraw(params.asset, msg.sender, params.to, amountToWithdraw);

        return amountToWithdraw;
    }
}
