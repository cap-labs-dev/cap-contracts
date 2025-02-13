// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IDelegation } from "../../interfaces/IDelegation.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { BorrowLogic } from "./BorrowLogic.sol";
import { ValidationLogic } from "./ValidationLogic.sol";
import { ViewLogic } from "./ViewLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Liquidation Logic
/// @author kexley, @capLabs
/// @notice Liquidate an agent that has an unhealthy ltv by slashing their delegation backing
library LiquidationLogic {
    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice A liquidation has been initiated against an agent
    event InitiateLiquidation(address agent);
    /// @notice A liquidation has been cancelled
    event CancelLiquidation(address agent);
    /// @notice An agent has been liquidated
    event Liquidate(address indexed agent, address indexed liquidator, address asset, uint256 amount, uint256 value);

    /// @notice Initiate the liquidation of an agent if unhealthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function initiateLiquidation(DataTypes.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,, uint256 health) = ViewLogic.agent($, _agent);

        ValidationLogic.validateInitiateLiquidation(health, $.liquidationStart[_agent], $.expiry);

        $.liquidationStart[_agent] = block.timestamp;

        emit InitiateLiquidation(_agent);
    }

    /// @notice Cancel the liquidation of an agent if healthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function cancelLiquidation(DataTypes.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,, uint256 health) = ViewLogic.agent($, _agent);

        ValidationLogic.validateCancelLiquidation(health);

        $.liquidationStart[_agent] = 0;

        emit CancelLiquidation(_agent);
    }

    /// @notice Liquidate an agent when their health is below 1
    /// @dev Liquidation must be initiated first and the grace period must have passed. Liquidation
    /// bonus linearly increases, once grace period has ended, up to the cap at expiry.
    /// All health factors, LTV ratios, and thresholds are in ray (1e27)
    /// @param $ Lender storage
    /// @param params Parameters to liquidate an agent
    /// @return liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(DataTypes.LenderStorage storage $, DataTypes.RepayParams memory params)
        external
        returns (uint256 liquidatedValue)
    {
        (uint256 totalDelegation, uint256 totalDebt,, uint256 liquidationThreshold, uint256 health) =
            ViewLogic.agent($, params.agent);

        ValidationLogic.validateLiquidation(health, $.liquidationStart[params.agent], $.grace, $.expiry);

        uint256 assetPrice = IOracle($.oracle).getPrice(params.asset);
        uint256 maxLiquidation = (($.targetHealth * totalDebt) - (totalDelegation * liquidationThreshold))
            * (10 ** $.reservesData[params.asset].decimals) / (($.targetHealth - liquidationThreshold) * assetPrice);
        uint256 liquidated = params.amount > maxLiquidation ? maxLiquidation : params.amount;

        liquidated = BorrowLogic.repay(
            $,
            DataTypes.RepayParams({ agent: params.agent, asset: params.asset, amount: liquidated, caller: params.caller })
        );

        uint256 bonus;
        if (totalDelegation > totalDebt) {
            uint256 elapsed = block.timestamp - ($.liquidationStart[params.agent] + $.grace);
            uint256 duration = $.expiry - $.grace;
            if (elapsed > duration) elapsed = duration;

            uint256 bonusPercentage = $.bonusCap * elapsed / duration;
            uint256 maxHealthyBonusPercentage = (totalDelegation - totalDebt) * 1e27 / totalDebt;
            if (bonusPercentage > maxHealthyBonusPercentage) bonusPercentage = maxHealthyBonusPercentage;

            bonus = liquidated * bonusPercentage / 1e27;
        }

        liquidatedValue = (liquidated + bonus) * assetPrice / (10 ** $.reservesData[params.asset].decimals);
        if (totalDelegation < liquidatedValue) liquidatedValue = totalDelegation;

        IDelegation($.delegation).slash(params.agent, params.caller, liquidatedValue);

        emit Liquidate(params.agent, params.caller, params.asset, liquidated, liquidatedValue);
    }
}
