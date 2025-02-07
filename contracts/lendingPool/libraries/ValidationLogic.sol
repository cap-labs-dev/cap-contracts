// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { INetwork } from "../../interfaces/INetwork.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { ViewLogic } from "./ViewLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Validation Logic
/// @author kexley, @capLabs
/// @notice Validate actions before state is altered
library ValidationLogic {
    /// @dev Collateral cannot cover new borrow
    error CollateralCannotCoverNewBorrow();

    /// @dev Health factor not below threshold
    error HealthFactorNotBelowThreshold();

    /// @dev Health factor lower than liquidation threshold
    error HealthFactorLowerThanLiquidationThreshold();

    /// @dev Already initiated
    error AlreadyInitiated();

    /// @dev Grace period not over
    error GracePeriodNotOver();

    /// @dev Liquidation expired
    error LiquidationExpired();

    /// @dev Reserve paused
    error ReservePaused();

    /// @dev Asset not listed
    error AssetNotListed();

    /// @dev Variable debt supply not zero
    error VariableDebtSupplyNotZero();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();    

    /// @dev Reserve already initialized
    error ReserveAlreadyInitialized();

    /// @notice Validate the borrow of an agent
    /// @dev Check the pause state of the reserve and the health of the agent before and after the 
    /// borrow.
    /// @param $ Lender storage
    /// @param params Validation parameters
    function validateBorrow(
        DataTypes.LenderStorage storage $,
        DataTypes.BorrowParams memory params
    ) external view {
        if ($.reservesData[params.asset].paused) revert ReservePaused();

        (uint256 totalDelegation, uint256 totalDebt,,, uint256 health) = ViewLogic.agent($, params.agent);

        if (health < 1e27) revert HealthFactorLowerThanLiquidationThreshold();

        uint256 ltv = INetwork($.delegation).ltv(params.agent);
        uint256 assetPrice = IOracle($.oracle).getPrice(params.asset);
        uint256 newTotalDebt = totalDebt + 
            ( params.amount * assetPrice / (10 ** $.reservesData[params.asset].decimals) );
        uint256 borrowCapacity = totalDelegation * ltv;
        
        if (newTotalDebt > borrowCapacity) revert CollateralCannotCoverNewBorrow();
    }

    /// @notice Validate the initialization of the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    /// @param start Last liquidation start time
    /// @param expiry Liquidation duration after which it expires
    function validateInitiateLiquidation(uint256 health, uint256 start, uint256 expiry) external view {
        if (health >= 1e27) revert HealthFactorNotBelowThreshold();
        if (block.timestamp <= start + expiry) revert AlreadyInitiated();
    }

    /// @notice Validate the cancellation of the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    function validateCancelLiquidation(uint256 health) external pure {
        if (health < 1e27) revert HealthFactorLowerThanLiquidationThreshold();
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
        if (health >= 1e27) revert HealthFactorNotBelowThreshold();
        if (block.timestamp <= start + grace) revert GracePeriodNotOver();
        if (block.timestamp >= start + expiry) revert LiquidationExpired();
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
        if (_asset == address(0) || _vault == address(0)) revert ZeroAddressNotValid();
        if ($.reservesData[_asset].vault != address(0)) revert ReserveAlreadyInitialized();
    }

    /// @notice Validate dropping an asset as a reserve
    /// @dev All principal borrows must be repaid, interest is ignored
    /// @param $ Lender storage
    /// @param _asset Asset to remove
    function validateRemoveAsset(
        DataTypes.LenderStorage storage $,
        address _asset
    ) external view {
        if (IERC20($.reservesData[_asset].principalDebtToken).totalSupply() != 0) revert VariableDebtSupplyNotZero();
    }

    /// @notice Validate pausing a reserve
    /// @param $ Lender storage
    /// @param _asset Asset to pause
    function validatePauseAsset(
        DataTypes.LenderStorage storage $,
        address _asset
    ) external view {
        if ($.reservesData[_asset].vault == address(0)) revert AssetNotListed();
    }
}
