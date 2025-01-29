// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { INetwork } from "../../interfaces/INetwork.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

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
    /// @param $ Lender storage
    /// @param params Validation parameters
    function validateBorrow(
        DataTypes.LenderStorage storage $,
        DataTypes.BorrowParams memory params
    ) external view {
        require(!$.reservesData[params.asset].paused, Errors.RESERVE_PAUSED);

        (uint256 totalDelegation, uint256 totalDebt,,, uint256 health) = ViewLogic.agent($, params.agent);

        require(health >= 1e27, Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD);

        uint256 ltv = INetwork($.delegation).ltv(params.agent);
        uint256 assetPrice = IOracle($.oracle).getPrice(params.asset);
        uint256 newTotalDebt = ( params.amount * assetPrice / $.reservesData[params.asset].decimals ) + totalDebt;
        uint256 borrowCapacity = totalDelegation * ltv;
        
        require(newTotalDebt <= borrowCapacity, Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW);
    }

    /// @notice Validate the initialization of the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    /// @param start Last liquidation start time
    /// @param expiry Liquidation duration after which it expires
    function validateInitiateLiquidation(uint256 health, uint256 start, uint256 expiry) external view {
        require(health < 1e27, Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD);
        require(block.timestamp > start + expiry, "AlreadyInitiated");
    }

    /// @notice Validate the cancellation of the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    function validateCancelLiquidation(uint256 health) external pure {
        require(health >= 1e27, Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD);
    }

    /// @notice Validate the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    /// @param start Last liquidation start time
    /// @param grace Grace period duration
    /// @param expiry Liquidation duration after which it expires
    function validateLiquidation(
        uint256 health,
        uint256 start,
        uint256 grace,
        uint256 expiry
    ) external view {
        require(health < 1e27, Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD);
        require(block.timestamp > start + grace, "Grace");
        require(block.timestamp < start + expiry, "Expired");
    }

    /// TODO Check that the asset is borrowable from the vault
    /// @notice Validate adding an asset as a reserve
    /// @param $ Lender storage
    /// @param _asset Asset to add
    /// @param _vault Vault to borrow asset from
    function validateAddAsset(
        DataTypes.LenderStorage storage $,
        address _asset,
        address _vault
    ) external view {
        require(_asset != address(0) && _vault != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require($.reservesData[_asset].vault == address(0), Errors.RESERVE_ALREADY_INITIALIZED);
    }

    /// @notice Validate dropping an asset as a reserve
    /// @dev All principal borrows must be repaid, interest is ignored
    /// @param $ Lender storage
    /// @param _asset Asset to remove
    function validateRemoveAsset(
        DataTypes.LenderStorage storage $,
        address _asset
    ) external view {
        require(
            IERC20($.reservesData[_asset].principalDebtToken).totalSupply() == 0,
            Errors.VARIABLE_DEBT_SUPPLY_NOT_ZERO
        );
    }

    /// @notice Validate pausing a reserve
    /// @param $ Lender storage
    /// @param _asset Asset to pause
    function validatePauseAsset(
        DataTypes.LenderStorage storage $,
        address _asset
    ) external view {
        require($.reservesData[_asset].vault != address(0), Errors.ASSET_NOT_LISTED);
    }
}
