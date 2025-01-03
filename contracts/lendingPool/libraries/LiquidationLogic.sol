// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICollateral} from "../../interfaces/ICollateral.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

import {ValidationLogic} from "./ValidationLogic.sol";
import {ViewLogic} from "./ViewLogic.sol";
import {BorrowLogic} from "./BorrowLogic.sol";
import {DataTypes} from "./types/DataTypes.sol";

/// @title Liquidation Logic
/// @author kexley, @capLabs
/// @notice Liquidate an agent that has an unhealthy ltv by slashing their collateral backing
library LiquidationLogic {
    /// @notice An agent has been liquidated
    event Liquidate(address indexed asset, address indexed agent, uint256 amount, uint256 value);

    /// @notice Liquidate an agent when their health is below 1
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
        (uint256 totalCollateral,,,, uint256 health) = ViewLogic.agent(
            reservesData,
            reservesList,
            agentConfig,
            DataTypes.AgentParams({
                agent: params.agent,
                collateral: params.collateral,
                oracle: params.oracle,
                reserveCount: params.reserveCount
            })
        );

        ValidationLogic.validateLiquidation(health);

        (uint256 liquidated,,) = BorrowLogic.repay(
            agentConfig,
            DataTypes.RepayParams({
                id: params.id,
                agent: params.agent,
                asset: params.asset,
                vault: params.vault,
                debtToken: params.debtToken,
                restakerDebtToken: params.restakerDebtToken,
                interestDebtToken: params.interestDebtToken,
                amount: params.amount,
                caller: params.caller,
                restakerRewarder: params.restakerRewarder,
                rewarder: params.rewarder
            })
        );

        if (params.bonus > 0) liquidated += params.bonus * liquidated;

        uint256 assetPrice = IPriceOracle(params.oracle).getPrice(params.asset);
        liquidatedValue = liquidated * assetPrice;
        if (totalCollateral < liquidatedValue) liquidatedValue = totalCollateral;

        ICollateral(params.collateral).slash(params.agent, params.caller, liquidatedValue);

        emit Liquidate(params.agent, params.asset, liquidated, liquidatedValue);
    }
}
