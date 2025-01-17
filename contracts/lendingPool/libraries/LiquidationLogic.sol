// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegation} from "../../interfaces/IDelegation.sol";
import {IOracle} from "../../interfaces/IOracle.sol";

import {ValidationLogic} from "./ValidationLogic.sol";
import {ViewLogic} from "./ViewLogic.sol";
import {BorrowLogic} from "./BorrowLogic.sol";
import {DataTypes} from "./types/DataTypes.sol";

/// @title Liquidation Logic
/// @author kexley, @capLabs
/// @notice Liquidate an agent that has an unhealthy ltv by slashing their delegation backing
library LiquidationLogic {
    /// @notice A liquidation has been initiated against an agent
    event InitiateLiquidation(address agent);
    /// @notice A liquidation has been cancelled
    event CancelLiquidation(address agent);
    /// @notice An agent has been liquidated
    event Liquidate(address indexed agent, address indexed liquidator, address asset, uint256 amount, uint256 value);

    /// @notice Initiate the liquidation of an agent if unhealthy
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param agentConfig Agent configuration
    /// @param liquidationStart Liquidation start timestamp
    /// @param params Parameters to initiate the liquidation
    function initiateLiquidation(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        mapping(address => uint256) storage liquidationStart,
        DataTypes.InitiateLiquidationParams memory params
    ) external {
        (,,,, uint256 health) = ViewLogic.agent(
            reservesData,
            reservesList,
            agentConfig,
            DataTypes.AgentParams({
                agent: params.agent,
                delegation: params.delegation,
                oracle: params.oracle,
                reserveCount: params.reserveCount
            })
        );

        ValidationLogic.validateInitiateLiquidation(health, liquidationStart[params.agent], params.expiry);

        liquidationStart[params.agent] = block.timestamp;

        emit InitiateLiquidation(params.agent);
    }

    /// @notice Cancel the liquidation of an agent if healthy
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param agentConfig Agent configuration
    /// @param liquidationStart Liquidation start timestamp
    /// @param params Parameters to cancel the liquidation
    function cancelLiquidation(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        mapping(address => uint256) storage liquidationStart,
        DataTypes.AgentParams memory params
    ) external {
        (,,,, uint256 health) = ViewLogic.agent(
            reservesData,
            reservesList,
            agentConfig,
            DataTypes.AgentParams({
                agent: params.agent,
                delegation: params.delegation,
                oracle: params.oracle,
                reserveCount: params.reserveCount
            })
        );

        ValidationLogic.validateCancelLiquidation(health);

        liquidationStart[params.agent] = 0;

        emit CancelLiquidation(params.agent);
    }

    /// @notice Liquidate an agent when their health is below 1
    /// @dev Liquidation must be initiated first and the grace period must have passed. Liquidation
    /// bonus linearly increases, once grace period has ended, up to the cap at expiry.
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param agentConfig Agent configuration
    /// @param params Parameters to liquidate an agent
    /// @return liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.LiquidateParams memory params
    ) external returns (uint256 liquidatedValue) {
        (uint256 totalDelegation, uint256 totalDebt,, uint256 liquidationThreshold, uint256 health) = ViewLogic.agent(
            reservesData,
            reservesList,
            agentConfig,
            DataTypes.AgentParams({
                agent: params.agent,
                delegation: params.delegation,
                oracle: params.oracle,
                reserveCount: params.reserveCount
            })
        );

        ValidationLogic.validateLiquidation(
            health,
            params.start,
            params.grace,
            params.expiry
        );

        uint256 assetPrice = IOracle(params.oracle).getPrice(params.asset);
        uint256 maxLiquidation = ((params.targetHealth * totalDebt) - (totalDelegation * liquidationThreshold)) 
            * params.decimals
            / ((params.targetHealth - liquidationThreshold) * assetPrice);
        uint256 liquidated = params.amount > maxLiquidation ? maxLiquidation : params.amount;

        (liquidated,,) = BorrowLogic.repay(
            reservesData,
            agentConfig,
            DataTypes.RepayParams({
                id: params.id,
                agent: params.agent,
                asset: params.asset,
                vault: params.vault,
                principalDebtToken: params.principalDebtToken,
                restakerDebtToken: params.restakerDebtToken,
                interestDebtToken: params.interestDebtToken,
                amount: liquidated,
                caller: params.caller,
                realizedInterest: params.realizedInterest,
                restakerInterestReceiver: params.restakerInterestReceiver,
                interestReceiver: params.interestReceiver
            })
        );

        uint256 elapsed = block.timestamp - (params.start + params.grace);
        uint256 duration = params.expiry - params.grace;
        if (elapsed > duration) elapsed = duration;
        uint256 bonus = liquidated * params.bonusCap * elapsed / (duration * 1e27);

        liquidatedValue = (liquidated + bonus) * assetPrice / params.decimals;
        if (totalDelegation < liquidatedValue) liquidatedValue = totalDelegation;

        IDelegation(params.delegation).slash(params.agent, params.caller, liquidatedValue);

        emit Liquidate(params.agent, params.caller, params.asset, liquidated, liquidatedValue);
    }
}
