// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICollateral } from "../../interfaces/ICollateral.sol";
import { IPriceOracle } from "../../interfaces/IPriceOracle.sol";

import { Errors } from "./helpers/Errors.sol";
import { ViewLogic } from "./ViewLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Validation Logic
/// @author kexley, @capLabs
/// @notice Validate actions before state is altered
library ValidationLogic {

    /// @notice Validate the borrow of an agent
    /// @dev Check the pause state of the reserve and the health of the agent before and after the 
    /// borrow.
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param reservesList List of all reserves
    /// @param agentConfig Agent configuration for borrowing
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

        require(health >= 1e27, Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD);

        uint256 ltv = ICollateral(params.collateral).ltv(params.agent);
        uint256 assetPrice = IPriceOracle(params.oracle).getPrice(params.asset);
        uint256 newTotalDebt = ( params.amount * assetPrice ) + totalDebt;
        uint256 borrowCapacity = totalCollateral * ltv;
        
        require(newTotalDebt <= borrowCapacity, Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW);
    }

    /// @notice Validate the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    function validateLiquidation(uint256 health) external pure {
        require(health >= 1e27, Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD);
    }

    /// TODO Check that the asset is borrowable from the vault
    /// @notice Validate adding an asset as a reserve
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param _asset Asset to add
    /// @param _vault Vault to borrow asset from
    function validateAddAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset,
        address _vault
    ) external view {
        require(_asset != address(0) && _vault != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(reservesData[_asset].vault == address(0), Errors.RESERVE_ALREADY_INITIALIZED);
    }

    /// @notice Validate dropping an asset as a reserve
    /// @dev All principal borrows must be repaid, interest is ignored
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param _asset Asset to remove
    function validateRemoveAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset
    ) external view {
        require(
            IERC20(reservesData[_asset].principalDebtToken).totalSupply() == 0,
            Errors.VARIABLE_DEBT_SUPPLY_NOT_ZERO
        );
    }

    /// @notice Validate pausing a reserve
    /// @param reservesData Reserve mapping that stores reserve data
    /// @param _asset Asset to pause
    function validatePauseAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset
    ) external view {
        require(reservesData[_asset].vault != address(0), Errors.ASSET_NOT_LISTED);
    }
}
