// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICollateral } from "../../interfaces/ICollateral.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { IDebtToken } from "../../interfaces/IDebtToken.sol";

import { Errors } from "./helpers/Errors.sol";
import { ViewLogic } from "./ViewLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

library ValidationLogic {
    /// @notice Validate the borrow of an agent
    /// @param params Validation parameters
    function validateBorrow(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AgentConfigurationMap storage agentConfig,
        DataTypes.ValidateBorrowParams memory params
    ) external view {
        require(!reservesData[params.asset].paused, Errors.RESERVE_PAUSED);

        (
            uint256 totalCollateral,
            uint256 totalDebt,
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

        require(health >= 1, Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD);

        uint256 ltv = ICollateral(params.collateral).ltv(params.agent);
        uint256 assetPrice = IOracle(params.oracle).getPrice(params.asset);
        uint256 newTotalDebt = ( params.amount * assetPrice ) + totalDebt;
        uint256 borrowCapacity = totalCollateral * ltv;
        
        require(newTotalDebt <= borrowCapacity, Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW);
    }

    /// @notice Validate the liquidation of an agent
    /// @param health Health of an agent's position
    function validateLiquidation(uint256 health) external pure {
        require(health >= 1, Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD);
    }

    function validateAddAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset,
        address _vault
    ) external view {
        require(_asset != address(0) && _vault != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(reservesData[_asset].vault == address(0), Errors.RESERVE_ALREADY_INITIALIZED);
    }

    function validateRemoveAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset
    ) external view {
        require(
            IDebtToken(reservesData[_asset].debtToken).totalSupply() == 0,
            Errors.VARIABLE_DEBT_SUPPLY_NOT_ZERO
        );
    }

    function validatePauseAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset
    ) external view {
        require(reservesData[_asset].vault != address(0), Errors.ASSET_NOT_LISTED);
    }
}