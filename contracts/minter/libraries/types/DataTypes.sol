// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultDataProvider} from "../../../interfaces/IVaultDataProvider.sol";

library DataTypes {

    struct MintBurnParams {
        address capToken;
        uint256 amountOut;
        address asset;
        uint256 amountIn;
        address vault;
        address receiver;
    }

    struct AmountOutParams {
        bool mint;
        address asset;
        uint256 amount;
        address capToken;
        address vault;
        address oracle;
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
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

    struct RedeemParams {
        address capToken;
        uint256 amount;
        address vault;
        address[] assets;
        uint256[] amountOuts;
        uint256[] minAmountOuts;
        address receiver;
    }

    struct RedeemAmountOutParams {
        address capToken;
        uint256 amount;
        address vault;
        address[] assets;
        uint256 redeemFee;
    }

    struct ValidateSwapParams {
        address vaultDataProvider;
        address tokenIn;
        address tokenOut;
        uint256 deadline;
    }
}