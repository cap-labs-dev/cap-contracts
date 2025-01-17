// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IDelegation } from "../../interfaces/IDelegation.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { AgentConfiguration } from "./configuration/AgentConfiguration.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title View Logic
/// @author kexley, @capLabs
/// @notice View functions to see the state of an agent's health
library ViewLogic {
    using AgentConfiguration for DataTypes.AgentConfigurationMap;

    /// @notice Calculate the agent data
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param agentConfig Agent configuration
    /// @param params Parameters for calculating an agent's data
    /// @return totalDelegation Total delegation of an agent
    /// @return totalDebt Total debt of an agent
    /// @return ltv Loan to value ratio
    /// @return liquidationThreshold Liquidation ratio of an agent
    /// @return health Health status of an agent
    function agent(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.AgentParams memory params
    ) external view returns (
        uint256 totalDelegation,
        uint256 totalDebt,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 health
    ) {
        totalDelegation = IDelegation(params.delegation).coverage(params.agent);
        liquidationThreshold = IDelegation(params.delegation).liquidationThreshold(params.agent);

        for (uint256 i; i < params.reserveCount; ++i) {
            if (!agentConfig.isBorrowing(i)) {
                continue;
            }

            address asset = reservesList[i];

            totalDebt += (
                IERC20(reservesData[asset].principalDebtToken).balanceOf(params.agent)
                + IERC20(reservesData[asset].interestDebtToken).balanceOf(params.agent)
                + IERC20(reservesData[asset].restakerDebtToken).balanceOf(params.agent)
            ) * IOracle(params.oracle).getPrice(asset) / reservesData[asset].decimals;
        }

        ltv = totalDebt / totalDelegation;
        health = totalDebt == 0 
            ? type(uint256).max 
            : totalDelegation * liquidationThreshold / totalDebt;
    }
}