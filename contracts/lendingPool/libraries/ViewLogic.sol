// SPDX-License-Identifier: BUSL-1.1
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
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @return totalDelegation Total delegation of an agent
    /// @return totalDebt Total debt of an agent
    /// @return ltv Loan to value ratio
    /// @return liquidationThreshold Liquidation ratio of an agent
    /// @return health Health status of an agent
    function agent(DataTypes.LenderStorage storage $, address _agent) external view returns (
        uint256 totalDelegation,
        uint256 totalDebt,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 health
    ) {
        totalDelegation = IDelegation($.delegation).coverage(_agent);
        liquidationThreshold = IDelegation($.delegation).liquidationThreshold(_agent);

        for (uint256 i; i < $.reservesCount; ++i) {
            if (!$.agentConfig[_agent].isBorrowing(i)) {
                continue;
            }

            address asset = $.reservesList[i];

            totalDebt += (
                IERC20($.reservesData[asset].principalDebtToken).balanceOf(_agent)
                + IERC20($.reservesData[asset].interestDebtToken).balanceOf(_agent)
                + IERC20($.reservesData[asset].restakerDebtToken).balanceOf(_agent)
            ) * IOracle($.oracle).getPrice(asset) / (10 ** $.reservesData[asset].decimals);
        }

        ltv = totalDebt / totalDelegation;
        health = totalDebt == 0 
            ? type(uint256).max 
            : totalDelegation * liquidationThreshold / totalDebt;
    }
}