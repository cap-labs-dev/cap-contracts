// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { IPToken } from "../../interfaces/IPToken.sol";

import { ValidationLogic } from "./ValidationLogic.sol";
import { AgentConfiguration } from './configuration/AgentConfiguration.sol';
import { DataTypes } from "./types/DataTypes.sol";

library BorrowLogic {
    using SafeERC20 for IERC20;
    using AgentConfiguration for DataTypes.AgentConfigurationMap;

    event Borrow(address indexed asset, address indexed agent, uint256 amount);
    event Repay(
        address indexed asset,
        address indexed agent,
        uint256 principalPaid,
        uint256 restakerPaid,
        uint256 interestPaid
    );
    event TotalRepayment(address indexed agent, address indexed asset);

    /// @notice Borrow an asset
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param agentConfig Agent configuration
    /// @param params Parameters to borrow an asset
    function borrow(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.BorrowParams memory params
    ) external {
        ValidationLogic.validateBorrow(
            reservesData,
            reservesList,
            agentConfig,
            DataTypes.ValidateBorrowParams({
                agent: params.agent,
                asset: params.asset,
                amount: params.amount,
                collateral: params.collateral,
                oracle: params.oracle,
                reserveCount: params.reserveCount
            })
        );

        if (!agentConfig.isBorrowing(params.id)) agentConfig.setBorrowing(params.id, true);

        IPToken(params.pToken).mint(params.agent, params.amount);

        IVault(params.vault).borrow(params.asset, params.amount, params.receiver);

        emit Borrow(params.agent, params.asset, params.amount);
    }

    /// @notice Repay an asset
    /// @param agentConfig Agent configuration
    /// @param params Parameters to repay a debt
    /// @return repaid Actual amount repaid
    /// @return restakerRepaid Actual restaker interest paid
    /// @return interestRepaid Actual market interest paid
    function repay(
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.RepayParams memory params
    ) external returns (uint256 repaid, uint256 restakerRepaid, uint256 interestRepaid) {
        repaid = params.amount > IERC20(params.pToken).balanceOf(params.agent)
            ? params.amount 
            :  IERC20(params.pToken).balanceOf(params.agent);

        (interestRepaid, restakerRepaid) 
            = IPToken(params.pToken).burn(params.agent, repaid, params.interest);

        if (repaid > 0) {
            IERC20(params.asset).safeTransferFrom(params.caller, address(this), repaid);
            IERC20(params.asset).forceApprove(params.vault, repaid);
            IVault(params.vault).repay(params.asset, repaid);
        }

        if (restakerRepaid > 0) {
            IERC20(params.asset).safeTransferFrom(params.caller, params.restakerRewarder, restakerRepaid);
        }

        if (interestRepaid > 0) {
            IERC20(params.asset).safeTransferFrom(params.caller, params.rewarder, interestRepaid);
        }

        if (IPToken(params.pToken).totalBalanceOf(params.agent) == 0) {
            agentConfig.setBorrowing(params.id, false);
            emit TotalRepayment(params.agent, params.asset);
        }

        emit Repay(params.agent, params.asset, repaid, restakerRepaid, interestRepaid);
    }
}