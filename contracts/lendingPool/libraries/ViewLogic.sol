// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IDelegation } from "../../interfaces/IDelegation.sol";

import { ILender } from "../../interfaces/ILender.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { AgentConfiguration } from "./configuration/AgentConfiguration.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title View Logic
/// @author kexley, @capLabs
/// @notice View functions to see the state of an agent's health
library ViewLogic {
    using AgentConfiguration for ILender.AgentConfigurationMap;

    /// @notice Calculate the agent data
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @return totalDelegation Total delegation of an agent in USD, encoded with 8 decimals
    /// @return totalSlashableCollateral Total slashable collateral of an agent in USD, encoded with 8 decimals
    /// @return totalDebt Total debt of an agent in USD, encoded with 8 decimals
    /// @return ltv Loan to value ratio, encoded in ray (1e27)
    /// @return liquidationThreshold Liquidation ratio of an agent, encoded in ray (1e27)
    /// @return health Health status of an agent, encoded in ray (1e27)
    function agent(ILender.LenderStorage storage $, address _agent)
        public
        view
        returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        )
    {
        totalDelegation = IDelegation($.delegation).coverage(_agent);
        totalSlashableCollateral = IDelegation($.delegation).slashableCollateral(_agent);
        liquidationThreshold = IDelegation($.delegation).liquidationThreshold(_agent);

        for (uint256 i; i < $.reservesCount; ++i) {
            if (!$.agentConfig[_agent].isBorrowing(i)) {
                continue;
            }

            address asset = $.reservesList[i];
            (uint256 assetPrice,) = IOracle($.oracle).getPrice(asset);
            if (assetPrice == 0) continue;

            ILender.ReserveData storage reserve = $.reservesData[asset];

            totalDebt += (IERC20(reserve.debtToken).balanceOf(_agent) + accruedRestakerInterest($, _agent, asset))
                * assetPrice / (10 ** reserve.decimals);
        }

        ltv = totalDelegation == 0 ? 0 : (totalDebt * 1e27) / totalDelegation;
        health = totalDebt == 0 ? type(uint256).max : (totalDelegation * liquidationThreshold) / totalDebt;
    }

    /// @notice Calculate the maximum amount that can be borrowed for a given asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to borrow
    /// @return maxBorrowableAmount Maximum amount that can be borrowed in asset decimals
    function maxBorrowable(ILender.LenderStorage storage $, address _agent, address _asset)
        external
        view
        returns (uint256 maxBorrowableAmount)
    {
        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 health) = agent($, _agent);

        // health is below liquidation threshold, no borrowing allowed
        if (health < 1e27) return 0;

        uint256 ltv = IDelegation($.delegation).ltv(_agent);
        uint256 borrowCapacity = totalDelegation * ltv / 1e27;

        //  already at or above borrow capacity
        if (totalDebt >= borrowCapacity) return 0;

        // Calculate remaining borrow capacity in USD (8 decimals)
        uint256 remainingCapacity = borrowCapacity - totalDebt;

        // Convert to asset amount using price and decimals
        (uint256 assetPrice,) = IOracle($.oracle).getPrice(_asset);
        if (assetPrice == 0) return 0;

        uint256 assetDecimals = $.reservesData[_asset].decimals;
        maxBorrowableAmount = remainingCapacity * (10 ** assetDecimals) / assetPrice;

        // Get total available assets using the vault's availableBalance function
        uint256 totalAvailable = IVault($.reservesData[_asset].vault).availableBalance(_asset);

        // Limit maxBorrowableAmount by total available assets
        if (totalAvailable < maxBorrowableAmount) {
            maxBorrowableAmount = totalAvailable;
        }
    }

    /// @notice Calculate the maximum amount that can be liquidated for a given asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to liquidate
    /// @return maxLiquidatableAmount Maximum amount that can be liquidated in asset decimals
    function maxLiquidatable(ILender.LenderStorage storage $, address _agent, address _asset)
        external
        view
        returns (uint256 maxLiquidatableAmount)
    {
        (uint256 totalDelegation,, uint256 totalDebt,, uint256 liquidationThreshold, uint256 health) = agent($, _agent);
        if (health >= 1e27) return 0;

        (uint256 assetPrice,) = IOracle($.oracle).getPrice(_asset);
        if (assetPrice == 0) return 0;

        uint256 decPow = 10 ** $.reservesData[_asset].decimals;
        uint256 a = ($.targetHealth * totalDebt);
        uint256 b = (totalDelegation * liquidationThreshold);
        uint256 c = ($.targetHealth - liquidationThreshold);
        uint256 d = assetPrice;
        uint256 e = b > a ? 0 : (a - b);
        uint256 f = (c * d);
        uint256 g = e * decPow;

        maxLiquidatableAmount = g / f;
    }

    /// @notice Get the current debt balances for an agent for a specific asset
    /// @param $ Lender storage
    /// @param _agent Agent address to check debt for
    /// @param _asset Asset to check debt for
    /// @return totalDebt Total debt amount in asset decimals
    function debt(ILender.LenderStorage storage $, address _agent, address _asset)
        external
        view
        returns (uint256 totalDebt)
    {
        totalDebt =
            IERC20($.reservesData[_asset].debtToken).balanceOf(_agent) + accruedRestakerInterest($, _agent, _asset);
    }

    /// @notice Calculate the accrued restaker interest for an agent for a specific asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to calculate accrued interest for
    /// @return accruedInterest Accrued restaker interest in asset decimals
    function accruedRestakerInterest(ILender.LenderStorage storage $, address _agent, address _asset)
        public
        view
        returns (uint256 accruedInterest)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 totalInterest = IERC20(reserve.debtToken).balanceOf(_agent);
        uint256 rate = IOracle($.oracle).restakerRate(_agent);
        uint256 elapsedTime = block.timestamp - reserve.lastRealizationTime[_agent];

        accruedInterest = totalInterest * rate * elapsedTime / 1e27;
    }
}
