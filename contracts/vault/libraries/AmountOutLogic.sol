// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IVaultUpgradeable } from "../../interfaces/IVaultUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Amount Out Logic
/// @author kexley, @capLabs
/// @notice Amount out logic for exchanging underlying assets with cap tokens
library AmountOutLogic {
    /// @notice Calculate the amount out from a swap including fees
    /// @param params Parameters for a swap
    /// @return amount Amount out from a swap
    function amountOut(DataTypes.AmountOutParams memory params) external view returns (uint256 amount) {
        (uint256 amountOutBeforeFee, uint256 newRatio) = _amountOutBeforeFee(params);

        amount = _applyFeeSlopes(
            DataTypes.FeeSlopeParams({
                mint: params.mint,
                amount: amountOutBeforeFee,
                ratio: newRatio,
                slope0: params.slope0,
                slope1: params.slope0,
                mintKinkRatio: params.mintKinkRatio,
                burnKinkRatio: params.burnKinkRatio,
                optimalRatio: params.optimalRatio
            })
        );
    }

    /// @notice Calculate the output amounts for redeeming a cap token for a proportional weighting
    /// @param params Parameters for redeeming
    /// @return amounts Amount of underlying assets withdrawn
    function redeemAmountOut(DataTypes.RedeemAmountOutParams memory params)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 shares = params.amount * 1e27 / IERC20(address(this)).totalSupply();
        address[] memory assets = IVaultUpgradeable(address(this)).assets();
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            uint256 withdrawAmount = IVaultUpgradeable(address(this)).totalSupplies(asset) * shares / 1e27;

            amounts[i] = withdrawAmount - (withdrawAmount * params.redeemFee / 1e27);
        }
    }

    /// @notice Calculate the amount out for a swap before fees
    /// @param params Parameters for a swap
    /// @return amount Amount out from a swap before fees
    /// @return newRatio New ratio of an asset to the overall basket after swap
    function _amountOutBeforeFee(DataTypes.AmountOutParams memory params)
        internal
        view
        returns (uint256 amount, uint256 newRatio)
    {
        uint256 assetPrice = IOracle(params.oracle).getPrice(params.asset);
        uint256 capPrice = IOracle(params.oracle).getPrice(address(this));

        uint8 assetDecimals = IERC20Metadata(params.asset).decimals();
        uint8 capDecimals = IERC20Metadata(address(this)).decimals();

        uint256 capSupply = IERC20(address(this)).totalSupply();
        uint256 capValue = capSupply * capPrice / capDecimals;
        uint256 allocationValue = IVaultUpgradeable(address(this)).totalSupplies(params.asset) * assetPrice / assetDecimals;

        uint256 assetValue;
        if (params.mint) {
            assetValue = params.amount * assetPrice / assetDecimals;
            if (capSupply == 0) {
                newRatio = 1e18;
                amount = params.amount * capDecimals / assetDecimals;
            } else {
                newRatio = (allocationValue + assetValue) * 1e27 / (capValue + assetValue);
                amount = assetValue * capDecimals / capPrice;
            }
        } else {
            assetValue = params.amount * capPrice / capDecimals;
            if (params.amount == capSupply) {
                newRatio = 1e18;
                amount = params.amount * assetDecimals / capDecimals;
            } else {
                newRatio = (allocationValue - assetValue) * 1e27 / (capValue - assetValue);
                amount = assetValue * assetDecimals / assetPrice;
            }
        }
    }

    /// @notice Apply fee slopes to a mint or burn
    /// @dev Fees only apply to mints or burns that over-allocate the basket to one asset
    /// @param params Fee slope parameters
    /// @return amount Remaining amount after fee applied
    function _applyFeeSlopes(DataTypes.FeeSlopeParams memory params)
        internal
        pure
        returns (uint256 amount)
    {
        uint256 rate;
        if (params.mint) {
            if (params.ratio > params.optimalRatio) {
                if (params.ratio > params.mintKinkRatio) {
                    uint256 excessRatio = params.ratio - params.mintKinkRatio;
                    rate = params.slope0 + (params.slope1 * excessRatio);
                } else {
                    rate = params.slope0 * params.ratio / params.mintKinkRatio;
                }
            }
        } else {
            if (params.ratio < params.optimalRatio) {
                if (params.ratio < params.burnKinkRatio) {
                    uint256 excessRatio = params.burnKinkRatio - params.ratio;
                    rate = params.slope0 + (params.slope1 * excessRatio);
                } else {
                    rate = params.slope0 * params.burnKinkRatio / params.ratio;
                }
            }
        }

        if (rate > 1e27) rate = 1e27;
        amount = params.amount - (params.amount * rate / 1e27);
    }
}
