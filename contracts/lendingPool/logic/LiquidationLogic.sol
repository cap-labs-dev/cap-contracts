// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts//IERC20.sol';
import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {PercentageMath} from '../../libraries/math/PercentageMath.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';
import {DataTypes} from '../../libraries/types/DataTypes.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {GenericLogic} from './GenericLogic.sol';
import {UserConfiguration} from '../../libraries/configuration/UserConfiguration.sol';
import {ReserveConfiguration} from '../../libraries/configuration/ReserveConfiguration.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';

/**
 * @title LiquidationLogic library
 * @author Aave
 * @notice Implements actions involving management of collateral in the protocol, the main one being the liquidations
 */
library LiquidationLogic {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using ReserveLogic for DataTypes.ReserveCache;
    using ReserveLogic for DataTypes.ReserveData;
    using UserConfiguration for DataTypes.UserConfigurationMap;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using GPv2SafeERC20 for IERC20;

    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator
    );

    /**
    * @dev Default percentage of borrower's debt to be repaid in a liquidation.
    * @dev Percentage applied when the users health factor is above `CLOSE_FACTOR_HF_THRESHOLD`
    * Expressed in bps, a value of 0.5e4 results in 50.00%
    */
    uint256 internal constant DEFAULT_LIQUIDATION_CLOSE_FACTOR = 0.5e4;

    /**
    * @dev Maximum percentage of borrower's debt to be repaid in a liquidation
    * @dev Percentage applied when the users health factor is below `CLOSE_FACTOR_HF_THRESHOLD`
    * Expressed in bps, a value of 1e4 results in 100.00%
    */
    uint256 public constant MAX_LIQUIDATION_CLOSE_FACTOR = 1e4;

    /**
    * @dev This constant represents below which health factor value it is possible to liquidate
    * an amount of debt corresponding to `MAX_LIQUIDATION_CLOSE_FACTOR`.
    * A value of 0.95e18 results in 0.95
    */
    uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;

    struct LiquidationCallLocalVars {
        uint256 userCollateralBalance;
        uint256 userTotalDebt;
        uint256 actualDebtToLiquidate;
        uint256 actualCollateralToLiquidate;
        uint256 healthFactor;
        DataTypes.ReserveCache debtReserveCache;
    }

    /**
    * @notice Function to liquidate a position if its Health Factor drops below 1. The caller (liquidator)
    * covers `debtToCover` amount of debt of the user getting liquidated, and receives
    * a proportional amount of the `collateralAsset` plus a bonus to cover market risk
    * @dev Emits the `LiquidationCall()` event
    * @param reservesData The state of all the reserves
    * @param reservesList The addresses of all the active reserves
    * @param usersConfig The users configuration mapping that track the supplied/borrowed assets
    * @param params The additional parameters needed to execute the liquidation function
    */
    function executeLiquidationCall(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        mapping(address => DataTypes.UserConfigurationMap) storage usersConfig,
        DataTypes.ExecuteLiquidationCallParams memory params
    ) external {
        LiquidationCallLocalVars memory vars;

        DataTypes.AvsData storage currentAvs = avsData[params.avs];
        DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset];
        DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.user];
        vars.debtReserveCache = debtReserve.cache();
        debtReserve.updateState(vars.debtReserveCache);

        (, , , , vars.healthFactor, ) = GenericLogic.calculateUserAccountData(
            reservesData,
            reservesList,
            avsData,
            avsList,
            DataTypes.CalculateUserAccountDataParams({
                userConfig: userConfig,
                reservesCount: params.reservesCount,
                user: params.user,
                oracle: params.priceOracle,
                avs: params.avs
            })
        );

        (vars.userTotalDebt, vars.actualDebtToLiquidate) = _calculateDebt(
            vars.debtReserveCache,
            params,
            vars.healthFactor
        );

        ValidationLogic.validateLiquidationCall(
            userConfig,
            currentAvs,
            debtReserve,
            DataTypes.ValidateLiquidationCallParams({
                debtReserveCache: vars.debtReserveCache,
                totalDebt: vars.userTotalDebt,
                healthFactor: vars.healthFactor,
                priceOracleSentinel: params.priceOracleSentinel,
                avs: params.avs
            })
        );

        vars.userCollateralBalance = IAvs(params.avs).coverage(params.user);

        (
            vars.actualCollateralToLiquidate,
            vars.actualDebtToLiquidate
        ) = _calculateAvailableCollateralToLiquidate(
            currentAvs,
            vars.debtReserveCache,
            currentAvs.underlyingAsset,
            params.debtAsset,
            vars.actualDebtToLiquidate,
            vars.userCollateralBalance,
            IPriceOracleGetter(params.priceOracle)
        );

        if (vars.userTotalDebt == vars.actualDebtToLiquidate) {
            userConfig.setBorrowing(debtReserve.id, false);
        }

        vars.debtReserveCache.nextScaledVariableDebt = IVariableDebtToken(
            vars.debtReserveCache.variableDebtTokenAddress
        ).burn(params.user, vars.actualDebtToLiquidate, vars.debtReserveCache.nextVariableBorrowIndex);

        debtReserve.updateInterestRatesAndBalance(
            vars.debtReserveCache,
            params.debtAsset,
            vars.actualDebtToLiquidate,
            0
        );

        IAvs(currentAvs.avs).slash(params.user, msg.sender, params.actualCollateralToLiquidate);

        // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
        IERC20(params.debtAsset).safeTransferFrom(
            msg.sender,
            vars.debtReserveCache.aTokenAddress,
            vars.actualDebtToLiquidate
        );

        emit LiquidationCall(
            params.avs,
            params.debtAsset,
            params.user,
            vars.actualDebtToLiquidate,
            vars.actualCollateralToLiquidate,
            msg.sender,
            params.receiveAToken
        );
    }

    /**
    * @notice Calculates the total debt of the user and the actual amount to liquidate depending on the health factor
    * and corresponding close factor.
    * @dev If the Health Factor is below CLOSE_FACTOR_HF_THRESHOLD, the close factor is increased to MAX_LIQUIDATION_CLOSE_FACTOR
    * @param debtReserveCache The reserve cache data object of the debt reserve
    * @param params The additional parameters needed to execute the liquidation function
    * @param healthFactor The health factor of the position
    * @return The total debt of the user
    * @return The actual debt to liquidate as a function of the closeFactor
    */
    function _calculateDebt(
        DataTypes.ReserveCache memory debtReserveCache,
        DataTypes.ExecuteLiquidationCallParams memory params,
        uint256 healthFactor
    ) internal view returns (uint256, uint256) {
        uint256 userVariableDebt = IERC20(debtReserveCache.variableDebtTokenAddress).balanceOf(
            params.user
        );

        uint256 closeFactor = healthFactor > CLOSE_FACTOR_HF_THRESHOLD
            ? DEFAULT_LIQUIDATION_CLOSE_FACTOR
            : MAX_LIQUIDATION_CLOSE_FACTOR;

        uint256 maxLiquidatableDebt = userVariableDebt.percentMul(closeFactor);

        uint256 actualDebtToLiquidate = params.debtToCover > maxLiquidatableDebt
            ? maxLiquidatableDebt
            : params.debtToCover;

        return (userVariableDebt, actualDebtToLiquidate);
    }

    struct AvailableCollateralToLiquidateLocalVars {
        uint256 collateralPrice;
        uint256 debtAssetPrice;
        uint256 maxCollateralToLiquidate;
        uint256 baseCollateral;
        uint256 bonusCollateral;
        uint256 debtAssetDecimals;
        uint256 collateralDecimals;
        uint256 collateralAssetUnit;
        uint256 debtAssetUnit;
        uint256 collateralAmount;
        uint256 debtAmountNeeded;
    }

    /**
    * @notice Calculates how much of a specific collateral can be liquidated, given
    * a certain amount of debt asset.
    * @dev This function needs to be called after all the checks to validate the liquidation have been performed,
    *   otherwise it might fail.
    * @param collateralReserve The data of the collateral reserve
    * @param debtReserveCache The cached data of the debt reserve
    * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
    * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
    * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
    * @param userCollateralBalance The collateral balance for the specific `collateralAsset` of the user being liquidated
    * @param liquidationBonus The collateral bonus percentage to receive as result of the liquidation
    * @return The maximum amount that is possible to liquidate given all the liquidation constraints (user balance, close factor)
    * @return The amount to repay with the liquidation
    */
    function _calculateAvailableCollateralToLiquidate(
        DataTypes.AvsData storage currentAvs,
        DataTypes.ReserveCache memory debtReserveCache,
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover,
        uint256 userCollateralBalance,
        IPriceOracleGetter oracle
    ) internal view returns (uint256, uint256, uint256) {
        AvailableCollateralToLiquidateLocalVars memory vars;

        vars.collateralPrice = oracle.getAssetPrice(collateralAsset);
        vars.debtAssetPrice = oracle.getAssetPrice(debtAsset);

        vars.collateralDecimals = currentAvs.configuration.getDecimals();
        vars.debtAssetDecimals = debtReserveCache.reserveConfiguration.getDecimals();

        unchecked {
            vars.collateralAssetUnit = 10 ** vars.collateralDecimals;
            vars.debtAssetUnit = 10 ** vars.debtAssetDecimals;
        }

        // This is the base collateral to liquidate based on the given debt to cover
        vars.baseCollateral =
            ((vars.debtAssetPrice * debtToCover * vars.collateralAssetUnit)) /
            (vars.collateralPrice * vars.debtAssetUnit);

        vars.maxCollateralToLiquidate = vars.baseCollateral;

        if (vars.maxCollateralToLiquidate > userCollateralBalance) {
            vars.collateralAmount = userCollateralBalance;
            vars.debtAmountNeeded = ((vars.collateralPrice * vars.collateralAmount * vars.debtAssetUnit) /
                (vars.debtAssetPrice * vars.collateralAssetUnit));
        } else {
            vars.collateralAmount = vars.maxCollateralToLiquidate;
            vars.debtAmountNeeded = debtToCover;
        }

        
        return (vars.collateralAmount, vars.debtAmountNeeded);
    }
}