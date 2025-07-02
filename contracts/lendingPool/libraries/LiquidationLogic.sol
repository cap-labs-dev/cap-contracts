// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IDelegation } from "../../interfaces/IDelegation.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { ILender } from "../../interfaces/ILender.sol";
import { BorrowLogic } from "./BorrowLogic.sol";
import { ValidationLogic } from "./ValidationLogic.sol";
import { ViewLogic } from "./ViewLogic.sol";

/// @title Liquidation Logic
/// @author kexley, Cap Labs
/// @notice Liquidate an agent that has an unhealthy ltv by slashing their delegation backing
library LiquidationLogic {
    /// @notice A liquidation has been initiated against an agent
    event InitiateLiquidation(address agent);

    /// @notice A liquidation has been cancelled
    event CancelLiquidation(address agent);

    /// @notice An agent has been liquidated
    event Liquidate(address indexed agent, address indexed liquidator, address asset, uint256 amount, uint256 value);

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Initiate the liquidation of an agent if unhealthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function initiateLiquidation(ILender.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,,, uint256 health) = ViewLogic.agent($, _agent);

        ValidationLogic.validateInitiateLiquidation(health, $.liquidationStart[_agent], $.expiry);

        $.liquidationStart[_agent] = block.timestamp;

        emit InitiateLiquidation(_agent);
    }

    /// @notice Cancel the liquidation of an agent if healthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function cancelLiquidation(ILender.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,,, uint256 health) = ViewLogic.agent($, _agent);

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
    function liquidate(ILender.LenderStorage storage $, ILender.RepayParams memory params)
        external
        returns (uint256 liquidatedValue)
    {
        (uint256 totalDelegation, uint256 totalSlashableCollateral, uint256 totalDebt,,, uint256 health) =
            ViewLogic.agent($, params.agent);

        ValidationLogic.validateLiquidation(
            health,
            totalDelegation * $.emergencyLiquidationThreshold / totalDebt,
            $.liquidationStart[params.agent],
            $.grace,
            $.expiry
        );

        (uint256 assetPrice,) = IOracle($.oracle).getPrice(params.asset);
        uint256 bonus = ViewLogic.bonus($, params.agent);
        uint256 maxLiquidation = ViewLogic.maxLiquidatable($, params.agent, params.asset);
        uint256 liquidated = params.amount > maxLiquidation ? maxLiquidation : params.amount;

        liquidated = BorrowLogic.repay(
            $,
            ILender.RepayParams({ agent: params.agent, asset: params.asset, amount: liquidated, caller: params.caller })
        );

        liquidatedValue =
            (liquidated + (liquidated * bonus / 1e27)) * assetPrice / (10 ** $.reservesData[params.asset].decimals);
        if (totalSlashableCollateral < liquidatedValue) liquidatedValue = totalSlashableCollateral;

        if (liquidatedValue > 0) IDelegation($.delegation).slash(params.agent, params.caller, liquidatedValue);

        emit Liquidate(params.agent, params.caller, params.asset, liquidated, liquidatedValue);
    }
}
