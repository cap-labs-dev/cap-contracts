// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICollateral } from "../../interfaces/ICollateral.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { ValidationLogic } from "./ValidationLogic.sol";
import { ViewLogic } from "./ViewLogic.sol";
import { BorrowLogic } from "./BorrowLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

library LiquidationLogic {

    event Liquidate(address indexed asset, address indexed agent, uint256 amount, uint256 value);

    /// @notice Liquidate an agent when the health is below 1
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
        (
            uint256 totalCollateral,
            ,
            ,
            ,
            uint256 health
        ) = ViewLogic.agent(
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

        (
            uint256 principalLiquidated, 
            uint256 restakerInterestLiquidated,
            uint256 interestLiquidated
        )= BorrowLogic.repay(
            agentConfig,
            DataTypes.RepayParams({
                id: params.id,
                agent: params.agent,
                asset: params.asset,
                vault: params.vault,
                pToken: params.pToken,
                amount: params.amount,
                interest: params.interest,
                caller: params.caller,
                restakerRewarder: params.restakerRewarder,
                rewarder: params.rewarder
            })
        );

        uint256 liquidated = principalLiquidated + restakerInterestLiquidated + interestLiquidated;

        uint256 assetPrice = IOracle(params.oracle).getPrice(params.asset);
        liquidatedValue = liquidated * assetPrice;
        if (totalCollateral < liquidatedValue) liquidatedValue = totalCollateral;

        ICollateral(params.collateral).slash(params.agent, params.caller, liquidatedValue);
        emit Liquidate(params.agent, params.asset, liquidated, liquidatedValue);
    }
}