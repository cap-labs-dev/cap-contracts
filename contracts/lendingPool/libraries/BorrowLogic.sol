// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IPrincipalDebtToken} from "../../interfaces/IPrincipalDebtToken.sol";
import {IDebtToken} from "../../interfaces/IDebtToken.sol";

import {ValidationLogic} from "./ValidationLogic.sol";
import {AgentConfiguration} from "./configuration/AgentConfiguration.sol";
import {DataTypes} from "./types/DataTypes.sol";

/// @title BorrowLogic
/// @author kexley, @capLabs
/// @notice Logic for borrowing and repaying assets from the Lender
/// @dev Interest rates for borrowing are not based on utilization like other lending markets.
/// Instead the rates are based on a benchmark rate per asset set by an admin or an alternative
/// lending market rate, whichever is higher. Indexes representing the increase of interest over
/// time are pulled from an oracle. A separate interest rate is set by admin per agent which is
/// paid to the restakers that guarantee the agent.
library BorrowLogic {
    using SafeERC20 for IERC20;
    using AgentConfiguration for DataTypes.AgentConfigurationMap;

    /// @dev An agent has borrowed an asset from the Lender
    event Borrow(address indexed asset, address indexed agent, uint256 amount);

    /// @dev An agent, or someone on behalf of an agent, has repaid
    event Repay(
        address indexed asset, address indexed agent, uint256 principalPaid, uint256 restakerPaid, uint256 interestPaid
    );

    /// @dev An agent has totally repaid their debt of an asset including all interests
    event TotalRepayment(address indexed agent, address indexed asset);

    /// @dev Realize interest before it is repaid by agents
    event RealizeInterest(address indexed asset, uint256 realizedInterest, address interestReceiver);

    /// @notice Borrow an asset from the Lender, minting a debt token which must be repaid
    /// @dev Interest debt token is updated before borrow happens to bring index up to date. Restaker
    /// debt token is updated after so the new principal debt can be used in calculations
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param reservesList List of all reserves
    /// @param agentConfig Agent configuration for borrowing
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

        IDebtToken(params.interestDebtToken).update(params.agent);
        IPrincipalDebtToken(params.principalDebtToken).mint(params.agent, params.amount);
        IDebtToken(params.restakerDebtToken).update(params.agent);

        IVault(params.vault).borrow(params.asset, params.amount, params.receiver);

        emit Borrow(params.agent, params.asset, params.amount);
    }

    /// @notice Repay an asset, burning the debt token and/or paying down interest
    /// @dev Only the amount owed or specified will be taken from the repayer, whichever is lower.
    /// Interest debt is paid first as the amount accrued is based on current principal debt, restaker
    /// debt is paid last as the future rate is calculated based on the resulting principal debt.
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param agentConfig Agent configuration for borrowing
    /// @param params Parameters to repay a debt
    /// @return principalRepaid Actual principal amount repaid
    /// @return restakerRepaid Actual restaker interest paid
    /// @return interestRepaid Actual market interest paid
    function repay(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.RepayParams memory params
    )
        external
        returns (uint256 principalRepaid, uint256 restakerRepaid, uint256 interestRepaid)
    {
        uint256 principalDebt = IERC20(params.principalDebtToken).balanceOf(params.agent);
        uint256 restakerDebt = IERC20(params.restakerDebtToken).balanceOf(params.agent);
        uint256 interestDebt = IERC20(params.interestDebtToken).balanceOf(params.agent);

        /// Maturity order of repayment is principal, restaker, then interest
        if (params.amount > principalDebt) {
            principalRepaid = params.amount - principalDebt;
            restakerRepaid =
                restakerDebt < params.amount - principalRepaid ? restakerDebt : params.amount - principalRepaid;
            interestRepaid = interestDebt < params.amount - principalRepaid - restakerRepaid
                ? interestDebt
                : params.amount - principalRepaid - restakerRepaid;
        } else {
            principalRepaid = params.amount;
        }

        if (interestRepaid > 0) {
            uint256 realizedInterestRepaid;
            if (params.realizedInterest > 0) {
                realizedInterestRepaid = interestRepaid < params.realizedInterest 
                    ? interestRepaid 
                    : params.realizedInterest;
                
                reservesData[params.asset].realizedInterest -= realizedInterestRepaid;
                IERC20(params.asset).safeTransferFrom(params.caller, address(this), realizedInterestRepaid);
                IERC20(params.asset).forceApprove(params.vault, realizedInterestRepaid);
                IVault(params.vault).repay(params.asset, realizedInterestRepaid);
            }

            interestRepaid = IDebtToken(params.interestDebtToken).burn(params.agent, interestRepaid);
            if (interestRepaid > realizedInterestRepaid) {
                IERC20(params.asset).safeTransferFrom(
                    params.caller, params.interestReceiver, interestRepaid - realizedInterestRepaid
                );
            }
        }

        if (principalRepaid > 0) {
            IPrincipalDebtToken(params.principalDebtToken).burn(params.agent, principalRepaid);
            IERC20(params.asset).safeTransferFrom(params.caller, address(this), principalRepaid);
            IERC20(params.asset).forceApprove(params.vault, principalRepaid);
            IVault(params.vault).repay(params.asset, principalRepaid);
        }

        if (restakerRepaid > 0) {
            restakerRepaid = IDebtToken(params.restakerDebtToken).burn(params.agent, restakerRepaid);
            IERC20(params.asset).safeTransferFrom(params.caller, params.restakerInterestReceiver, restakerRepaid);
        }

        if (
            IERC20(params.principalDebtToken).balanceOf(params.agent) == 0
                && IERC20(params.restakerDebtToken).balanceOf(params.agent) == 0
                && IERC20(params.interestDebtToken).balanceOf(params.agent) == 0
        ) {
            agentConfig.setBorrowing(params.id, false);
            emit TotalRepayment(params.agent, params.asset);
        }

        emit Repay(params.agent, params.asset, principalRepaid, restakerRepaid, interestRepaid);
    }

    /// @notice Realize the interest before it is repaid by borrowing from the vault
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param params Parameters for realizing interest
    /// @return realizedInterest Actual realized interest
    function realizeInterest(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        DataTypes.RealizeInterestParams memory params
    ) external returns (uint256 realizedInterest) {
        uint256 totalInterest = IERC20(params.interestDebtToken).totalSupply();
        uint256 maxRealization = totalInterest > params.realizedInterest ? totalInterest - params.realizedInterest : 0;
        realizedInterest = params.amount > maxRealization ? maxRealization : params.amount;

        reservesData[params.asset].realizedInterest += realizedInterest;
        IVault(params.vault).borrow(params.asset, realizedInterest, params.interestReceiver);
        emit RealizeInterest(params.asset, realizedInterest, params.interestReceiver);
    }
}
