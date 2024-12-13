// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {ReserveLogic} from './ReserveLogic.sol';
/**
 * @title GenericLogic library
 * @author Aave
 * @notice Implements protocol-level logic to calculate and validate the state of a user
 */
library GenericLogic {
    using ReserveLogic for DataTypes.ReserveData;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    struct CalculateUserAccountDataVars {
        uint256 assetPrice;
        uint256 assetUnit;
        uint256 userBalanceInBaseCurrency;
        uint256 decimals;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 i;
        uint256 healthFactor;
        uint256 totalCollateralInBaseCurrency;
        uint256 totalDebtInBaseCurrency;
        uint256 avgLtv;
        uint256 avgLiquidationThreshold;
        address currentReserveAddress;
    }

    /**
    * @notice Calculates the user data across the reserves.
    * @dev It includes the total liquidity/collateral/borrow balances in the base currency used by the price feed,
    * the average Loan To Value, the average Liquidation Ratio, and the Health factor.
    * @param reservesData The state of all the reserves
    * @param reservesList The addresses of all the active reserves
    * @param params Additional parameters needed for the calculation
    * @return The total collateral of the user in the base currency used by the price feed
    * @return The total debt of the user in the base currency used by the price feed
    * @return The average ltv of the user
    * @return The average liquidation threshold of the user
    * @return The health factor of the user
    */
    function calculateUserAccountData(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.CalculateUserAccountDataParams memory params
    ) internal view returns (uint256, uint256, uint256, uint256, uint256) {
        CalculateUserAccountDataVars memory vars;

        while (vars.i < params.reservesCount) {
            if (!params.userConfig.isBorrowing(vars.i)) {
                unchecked {
                    ++vars.i;
                }
                continue;
            }

            vars.currentReserveAddress = reservesList[vars.i];

            if (vars.currentReserveAddress == address(0)) {
                unchecked {
                    ++vars.i;
                }
                continue;
            }

            DataTypes.ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];

            ( , , , vars.decimals, ) = currentReserve
                .configuration
                .getParams();

            unchecked {
                vars.assetUnit = 10 ** vars.decimals;
            }

            vars.assetPrice = IPriceOracleGetter(params.oracle).getAssetPrice(vars.currentReserveAddress);

            if (params.userConfig.isBorrowing(vars.i)) {
                vars.totalDebtInBaseCurrency += _getUserDebtInBaseCurrency(
                    params.user,
                    currentReserve,
                    vars.assetPrice,
                    vars.assetUnit
                );
            }

            unchecked {
                ++vars.i;
            }
        }

        totalCollateralInBaseCurrency = params.avs.coverage(params.user);
        vars.ltv = params.avs.ltv(params.user);
        vars.liquidationThreshold = params.avs.liquidationThreshold(params.user);

        vars.healthFactor = vars.totalDebtInBaseCurrency == 0
            ? type(uint256).max
            : (vars.totalCollateralInBaseCurrency.percentMul(vars.liquidationThreshold)).wadDiv(
                vars.totalDebtInBaseCurrency
        );

        return (
            vars.totalCollateralInBaseCurrency,
            vars.totalDebtInBaseCurrency,
            vars.ltv,
            vars.liquidationThreshold,
            vars.healthFactor
        );
    }

    /**
    * @notice Calculates the maximum amount that can be borrowed depending on the available collateral, the total debt
    * and the average Loan To Value
    * @param totalCollateralInBaseCurrency The total collateral in the base currency used by the price feed
    * @param totalDebtInBaseCurrency The total borrow balance in the base currency used by the price feed
    * @param ltv The average loan to value
    * @return The amount available to borrow in the base currency of the used by the price feed
    */
    function calculateAvailableBorrows(
        uint256 totalCollateralInBaseCurrency,
        uint256 totalDebtInBaseCurrency,
        uint256 ltv
    ) internal pure returns (uint256) {
        uint256 availableBorrowsInBaseCurrency = totalCollateralInBaseCurrency.percentMul(ltv);

        if (availableBorrowsInBaseCurrency <= totalDebtInBaseCurrency) {
            return 0;
        }

        availableBorrowsInBaseCurrency = availableBorrowsInBaseCurrency - totalDebtInBaseCurrency;
        return availableBorrowsInBaseCurrency;
    }

    /**
    * @notice Calculates total debt of the user in the based currency used to normalize the values of the assets
    * @dev This fetches the `balanceOf` of the variable debt token for the user. For gas reasons, the
    * variable debt balance is calculated by fetching `scaledBalancesOf` normalized debt, which is cheaper than
    * fetching `balanceOf`
    * @param user The address of the user
    * @param reserve The data of the reserve for which the total debt of the user is being calculated
    * @param assetPrice The price of the asset for which the total debt of the user is being calculated
    * @param assetUnit The value representing one full unit of the asset (10^decimals)
    * @return The total debt of the user normalized to the base currency
    */
    function _getUserDebtInBaseCurrency(
        address user,
        DataTypes.ReserveData storage reserve,
        uint256 assetPrice,
        uint256 assetUnit
    ) private view returns (uint256) {
        // fetching variable debt
        uint256 userTotalDebt = IScaledBalanceToken(reserve.variableDebtTokenAddress).scaledBalanceOf(
            user
        );
        if (userTotalDebt == 0) {
            return 0;
        }

        userTotalDebt = userTotalDebt.rayMul(reserve.getNormalizedDebt()) * assetPrice;
        unchecked {
            return userTotalDebt / assetUnit;
        }
    }
}
