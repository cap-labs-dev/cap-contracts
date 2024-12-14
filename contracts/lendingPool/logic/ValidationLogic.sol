// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {Address} from '../../../dependencies/openzeppelin/contracts/Address.sol';
import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {IPriceOracleSentinel} from '../../../interfaces/IPriceOracleSentinel.sol';
import {IPoolAddressesProvider} from '../../../interfaces/IPoolAddressesProvider.sol';
import {IAccessControl} from '../../../dependencies/openzeppelin/contracts/IAccessControl.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {Errors} from '../helpers/Errors.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {GenericLogic} from './GenericLogic.sol';
import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {IncentivizedERC20} from '../../tokenization/base/IncentivizedERC20.sol';

/// @title ValidationLogic library
/// @author kexley, inspired by Aave
/// @notice Implements functions to validate the different actions of the protocol
library ValidationLogic {
    using ReserveLogic for DataTypes.ReserveData;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeCast for uint256;
    using GPv2SafeERC20 for IERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using UserConfiguration for DataTypes.UserConfigurationMap;
    using Address for address;

    // Minimum health factor allowed under any circumstance
    // A value of 0.95e18 results in 0.95
    uint256 public constant MINIMUM_HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 0.95e18;

    /**
    * @dev Minimum health factor to consider a user position healthy
    * A value of 1e18 results in 1
    */
    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;

    /// @notice Validates a supply action
    /// @param reserveCache The cached data of the reserve
    /// @param reserve The storage pointer of the reserve
    /// @param amount The amount to be supplied
    /// @param onBehalfOf Receiver of the cTokens
    function validateSupply(
        DataTypes.ReserveCache memory reserveCache,
        DataTypes.ReserveData storage reserve,
        uint256 amount,
        address onBehalfOf
    ) internal view {
        require(amount != 0, Errors.INVALID_AMOUNT);

        (bool isActive, bool isFrozen, , bool isPaused) = reserveCache.reserveConfiguration.getFlags();
        require(isActive, Errors.RESERVE_INACTIVE);
        require(!isPaused, Errors.RESERVE_PAUSED);
        require(!isFrozen, Errors.RESERVE_FROZEN);
        require(onBehalfOf != reserveCache.aTokenAddress, Errors.SUPPLY_TO_ATOKEN);

        uint256 supplyCap = reserveCache.reserveConfiguration.getSupplyCap();
        require(
            supplyCap == 0 ||
                ((IAToken(reserveCache.cToken).totalSupply() +
                    uint256(reserve.accruedToTreasury)) + amount) <=
                        supplyCap * (10 ** reserveCache.reserveConfiguration.getDecimals()),
            Errors.SUPPLY_CAP_EXCEEDED
        );
    }

    /// @notice Validates a withdraw action
    /// @param reserveCache The cached data of the reserve
    /// @param amount The amount to be withdrawn
    /// @param userBalance The balance of the user
    function validateWithdraw(
        DataTypes.ReserveCache memory reserveCache,
        uint256 amount,
        uint256 userBalance
    ) internal pure {
        require(amount != 0, Errors.INVALID_AMOUNT);
        require(amount <= userBalance, Errors.NOT_ENOUGH_AVAILABLE_USER_BALANCE);

        (bool isActive, , , bool isPaused) = reserveCache.reserveConfiguration.getFlags();
        require(isActive, Errors.RESERVE_INACTIVE);
        require(!isPaused, Errors.RESERVE_PAUSED);
    }

    struct ValidateBorrowLocalVars {
        uint256 currentLtv;
        uint256 collateralNeededInBaseCurrency;
        uint256 userCollateralInBaseCurrency;
        uint256 userDebtInBaseCurrency;
        uint256 availableLiquidity;
        uint256 healthFactor;
        uint256 totalDebt;
        uint256 totalSupplyVariableDebt;
        uint256 reserveDecimals;
        uint256 borrowCap;
        uint256 amountInBaseCurrency;
        uint256 assetUnit;
        bool isActive;
        bool isFrozen;
        bool isPaused;
        bool borrowingEnabled;
    }

    /// @notice Validates a borrow action
    /// @param reservesData The state of all the reserves
    /// @param reservesList The addresses of all the active reserves
    /// @param params Additional params needed for the validation
    function validateBorrow(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.ValidateBorrowParams memory params
    ) internal view {
        require(params.amount != 0, Errors.INVALID_AMOUNT);

        ValidateBorrowLocalVars memory vars;

        (vars.isActive, vars.isFrozen, vars.borrowingEnabled, vars.isPaused) = params
            .reserveCache
            .reserveConfiguration
            .getFlags();

        require(vars.isActive, Errors.RESERVE_INACTIVE);
        require(!vars.isPaused, Errors.RESERVE_PAUSED);
        require(!vars.isFrozen, Errors.RESERVE_FROZEN);
        require(vars.borrowingEnabled, Errors.BORROWING_NOT_ENABLED);
        require(
            IERC20(params.reserveCache.aTokenAddress).totalSupply() >= params.amount,
            Errors.INVALID_AMOUNT
        );

        require(
            params.priceOracleSentinel == address(0) ||
            IPriceOracleSentinel(params.priceOracleSentinel).isBorrowAllowed(),
            Errors.PRICE_ORACLE_SENTINEL_CHECK_FAILED
        );

        vars.reserveDecimals = params.reserveCache.reserveConfiguration.getDecimals();
        vars.borrowCap = params.reserveCache.reserveConfiguration.getBorrowCap();
        unchecked {
            vars.assetUnit = 10 ** vars.reserveDecimals;
        }

        if (vars.borrowCap != 0) {
            vars.totalSupplyVariableDebt = params.reserveCache.currScaledVariableDebt.rayMul(
                params.reserveCache.nextVariableBorrowIndex
            );

            vars.totalDebt = vars.totalSupplyVariableDebt + params.amount;

            unchecked {
                require(vars.totalDebt <= vars.borrowCap * vars.assetUnit, Errors.BORROW_CAP_EXCEEDED);
            }
        }

        (
            vars.userCollateralInBaseCurrency,
            vars.userDebtInBaseCurrency,
            vars.currentLtv,
            ,
            vars.healthFactor
        ) = GenericLogic.calculateUserAccountData(
            reservesData,
            reservesList,
            DataTypes.CalculateUserAccountDataParams({
                userConfig: params.userConfig,
                reservesCount: params.reservesCount,
                avsCount: params.avsCount,
                user: params.userAddress,
                oracle: params.oracle,
                avs: params.avs
            })
        );

        require(vars.userCollateralInBaseCurrency != 0, Errors.COLLATERAL_BALANCE_IS_ZERO);
        require(vars.currentLtv != 0, Errors.LTV_VALIDATION_FAILED);

        require(
            vars.healthFactor > HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD
        );

        vars.amountInBaseCurrency =
            IPriceOracleGetter(params.oracle).getAssetPrice(params.asset) * params.amount;
        unchecked {
            vars.amountInBaseCurrency /= vars.assetUnit;
        }

        //add the current already borrowed amount to the amount requested to calculate the total collateral needed.
        vars.collateralNeededInBaseCurrency = (vars.userDebtInBaseCurrency + vars.amountInBaseCurrency)
            .percentDiv(vars.currentLtv); //LTV is calculated in percentage

        require(
            vars.collateralNeededInBaseCurrency <= vars.userCollateralInBaseCurrency,
            Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW
        );
    }

    /// @notice Validates a repay action.
    /// @param reserveCache The cached data of the reserve
    /// @param amountSent The amount sent for the repayment. Can be an actual value or uint(-1)
    /// @param onBehalfOf The address of the user msg.sender is repaying for
    /// @param debt The borrow balance of the user
    function validateRepay(
        DataTypes.ReserveCache memory reserveCache,
        uint256 amountSent,
        address onBehalfOf,
        uint256 debt
    ) internal view {
        require(amountSent != 0, Errors.INVALID_AMOUNT);
        require(
            amountSent != type(uint256).max || msg.sender == onBehalfOf,
            Errors.NO_EXPLICIT_AMOUNT_TO_REPAY_ON_BEHALF
        );

        (bool isActive, , , bool isPaused) = reserveCache.reserveConfiguration.getFlags();
        require(isActive, Errors.RESERVE_INACTIVE);
        require(!isPaused, Errors.RESERVE_PAUSED);

        require(debt != 0, Errors.NO_DEBT);
    }

    struct ValidateLiquidationCallLocalVars {
        bool principalReserveActive;
        bool principalReservePaused;
    }

    /// @notice Validates the liquidation action
    /// @param userConfig The user configuration mapping
    /// @param debtReserve The reserve data of the debt
    /// @param params Additional parameters needed for the validation
    function validateLiquidationCall(
        DataTypes.UserConfigurationMap storage userConfig,
        DataTypes.ReserveData storage debtReserve,
        DataTypes.ValidateLiquidationCallParams memory params
    ) internal view {
        ValidateLiquidationCallLocalVars memory vars;

        (vars.principalReserveActive, , , vars.principalReservePaused) = params
            .debtReserveCache
            .reserveConfiguration
            .getFlags();

        require(vars.principalReserveActive, Errors.RESERVE_INACTIVE);
        require(!vars.principalReservePaused, Errors.RESERVE_PAUSED);

        require(
            params.priceOracleSentinel == address(0)
                || params.healthFactor < MINIMUM_HEALTH_FACTOR_LIQUIDATION_THRESHOLD 
                || IPriceOracleSentinel(params.priceOracleSentinel).isLiquidationAllowed(),
            Errors.PRICE_ORACLE_SENTINEL_CHECK_FAILED
        );

        require(
            debtReserve.liquidationGracePeriodUntil < uint40(block.timestamp),
            Errors.LIQUIDATION_GRACE_SENTINEL_CHECK_FAILED
        );

        require(
            params.healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD
        );
    }

    /// @notice Validates a drop reserve action
    /// @param reservesList The addresses of all the active reserves
    /// @param reserve The reserve object
    /// @param asset The address of the reserve's underlying asset
    function validateDropReserve(
        mapping(uint256 => address) storage reservesList,
        DataTypes.ReserveData storage reserve,
        address asset
    ) internal view {
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(reserve.id != 0 || reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
        require(
            IERC20(reserve.vToken).totalSupply() == 0,
            Errors.VARIABLE_DEBT_SUPPLY_NOT_ZERO
        );
        require(
            IERC20(reserve.cToken).totalSupply() == 0 && reserve.accruedToTreasury == 0,
            Errors.UNDERLYING_CLAIMABLE_RIGHTS_NOT_ZERO
        );
    }
}