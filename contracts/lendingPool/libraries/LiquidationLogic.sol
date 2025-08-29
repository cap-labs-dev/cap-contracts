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
    /// @notice A liquidation window has been opened against an agent
    event OpenLiquidation(address agent);

    /// @notice A liquidation window has been closed
    event CloseLiquidation(address agent);

    /// @notice An agent has been liquidated
    event Liquidate(address indexed agent, address indexed liquidator, address asset, uint256 amount, uint256 value);

    /// @notice No debt to liquidate
    error NoDebt();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Insufficient liquidation value
    error InsufficientLiquidationValue();

    /// @notice Open the liquidation window of an agent if unhealthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function openLiquidation(ILender.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,,, uint256 health) = ViewLogic.agent($, _agent);

        ValidationLogic.validateOpenLiquidation(health, $.liquidationStart[_agent], $.expiry);

        $.liquidationStart[_agent] = block.timestamp;

        emit OpenLiquidation(_agent);
    }

    /// @notice Close the liquidation window of an agent if healthy
    /// @param $ Lender storage
    /// @param _agent Agent address
    function closeLiquidation(ILender.LenderStorage storage $, address _agent) external {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        (,,,,, uint256 health) = ViewLogic.agent($, _agent);

        ValidationLogic.validateCloseLiquidation(health);

        _closeLiquidation($, _agent);
    }

    /// @notice Liquidate an agent when their health is below 1
    /// @dev Liquidation must be opened first and the grace period must have passed. Liquidation
    /// bonus linearly increases, once grace period has ended, up to the cap at expiry.
    /// All health factors, LTV ratios, and thresholds are in ray (1e27)
    /// @param $ Lender storage
    /// @param params Parameters to liquidate an agent
    /// @param _minLiquidatedValue Minimum value of the liquidation returned to the liquidator
    /// @return liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(ILender.LenderStorage storage $, ILender.RepayParams memory params, uint256 _minLiquidatedValue)
        external
        returns (uint256 liquidatedValue)
    {
        (uint256 totalDelegation, uint256 totalSlashableCollateral, uint256 totalDebt,,, uint256 health) =
            ViewLogic.agent($, params.agent);

        if (totalDebt == 0) revert NoDebt();

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
        if (liquidatedValue < _minLiquidatedValue) revert InsufficientLiquidationValue();

        if (liquidatedValue > 0) IDelegation($.delegation).slash(params.agent, params.caller, liquidatedValue);

        (,,,,, health) = ViewLogic.agent($, params.agent);
        if (health >= 1e27) _closeLiquidation($, params.agent);

        emit Liquidate(params.agent, params.caller, params.asset, liquidated, liquidatedValue);
    }

    /// @dev Cancel further liquidations with no checks
    /// @param $ Lender storage
    /// @param _agent Agent address
    function _closeLiquidation(ILender.LenderStorage storage $, address _agent) internal {
        $.liquidationStart[_agent] = 0;
        emit CloseLiquidation(_agent);
    }
}
