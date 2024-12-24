// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { DataTypes } from "./types/DataTypes.sol";

/// @title Amount out Logic
/// @author kexley, @capLabs
/// @notice Amount out logic for exchanging underlying assets with cap tokens
library AmountOutLogic {

    /// @notice Calculate the output amounts for redeeming a cap token for a proportional weighting
    /// @param params Parameters for redeeming
    /// @return amounts Amount of underlying assets withdrawn
    /// @return fees Burning fee amounts
    function redeemAmountOut(
        DataTypes.RedeemAmountOutParams memory params
    ) external view returns (uint256[] memory amounts, uint256[] memory fees) {
        uint256 shares = params.amount / IERC20(params.capToken).totalSupply();
        uint256 assetLength = params.assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = params.assets[i];
            uint256 withdrawAmount = IVault(params.vault).totalSupplies(asset) * shares;

            fees[i] = withdrawAmount * params.redeemFee / 1e27;
            amounts[i] = withdrawAmount - fees[i];
        }
    }

    /// @notice Calculate the amount out from a swap including fees
    /// @param params Parameters for a swap
    /// @return amount Amount out from a swap
    /// @return fee Fee amount
    function amountOut(
        DataTypes.AmountOutParams memory params
    ) external view returns (uint256 amount, uint256 fee) {
        (uint256 amountOutBeforeFee, uint256 newRatio) = _amountOutBeforeFee(params);

        (amount, fee) = _applyFeeSlopes(
            DataTypes.FeeSlopeParams({
                mint: params.mint,
                amount: amountOutBeforeFee,
                ratio: newRatio,
                basketFees: params.basketFees
            })
        );
    }

    /// @notice Calculate the amount out for a swap before fees
    /// @param params Parameters for a swap
    /// @return amount Amount out from a swap before fees
    /// @return newRatio New ratio of an asset to the overall basket after swap
    function _amountOutBeforeFee(
        DataTypes.AmountOutParams memory params
    ) internal view returns (uint256 amount, uint256 newRatio) {
        uint256 basketValue;
        uint256 mintValue;
        uint256 basketAssetValue;
        uint256 assetPrice;
        uint256 assetLength = params.assets.length;

        for (uint256 i; i < assetLength; ++i) {
            address asset = params.assets[i];
            uint256 price = IOracle(params.oracle).getPrice(asset);
            uint256 value = IVault(params.vault).totalSupplies(asset) * price;

            if (asset == params.asset) {
                basketAssetValue = value;
                assetPrice = price;
                if (params.mint) mintValue = params.amount * price;
            }

            basketValue += value;
        }

        if (params.mint) {
            newRatio = ( basketAssetValue + mintValue ) * 1e27 / ( basketValue + mintValue );
            amount = mintValue * IERC20(params.capToken).totalSupply() / basketValue;
        } else {
            mintValue = params.amount * basketValue / IERC20(params.capToken).totalSupply();
            newRatio = ( basketAssetValue - mintValue ) * 1e27 / ( basketValue - mintValue );
            amount = mintValue / assetPrice;
        }
    }

    /// @notice Apply fee slopes to a mint or burn
    /// @dev Fees only apply to mints or burns that over-allocate the basket to one asset
    /// @param params Fee slope parameters
    /// @return amount Remaining amount after fee applied
    /// @return fee Fee amount applied
    function _applyFeeSlopes(
        DataTypes.FeeSlopeParams memory params
    ) internal pure returns (uint256 amount, uint256 fee) {
        uint256 rate;
        if (params.mint) {
            if (params.ratio > params.basketFees.optimalRatio) {
                if (params.ratio > params.basketFees.mintKinkRatio) {
                    uint256 excessRatio = params.ratio - params.basketFees.mintKinkRatio;
                    rate = params.basketFees.slope0 + ( params.basketFees.slope1 * excessRatio );
                } else {
                    rate = params.basketFees.slope0 * params.ratio / params.basketFees.mintKinkRatio;
                }
            }
        } else {
            if (params.ratio < params.basketFees.optimalRatio) {
                if (params.ratio < params.basketFees.burnKinkRatio) {
                    uint256 excessRatio = params.basketFees.burnKinkRatio - params.ratio;
                    rate = params.basketFees.slope0 + ( params.basketFees.slope1 * excessRatio );
                } else {
                    rate = params.basketFees.slope0 * params.basketFees.burnKinkRatio / params.ratio;
                }
            }
        }

        if (rate > 1e27) rate = 1e27;
        fee = params.amount * rate / 1e27;
        amount = params.amount - fee;
    }
}
