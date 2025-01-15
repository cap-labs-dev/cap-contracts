// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultDataProvider} from "../../../interfaces/IVaultDataProvider.sol";

library DataTypes {
    struct FeeData {
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    struct AmountOutParams {
        bool mint;
        address asset;
        uint256 amount;
        address oracle;
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    struct RedeemAmountOutParams {
        uint256 amount;
        uint256 redeemFee;
    }

    struct FeeSlopeParams {
        bool mint;
        uint256 amount;
        uint256 ratio;
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }
}
