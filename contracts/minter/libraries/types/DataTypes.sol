// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
        address[] assets;
        BasketFees basketFees;
    }

    struct FeeSlopeParams {
        bool mint;
        uint256 amount;
        uint256 ratio;
        BasketFees basketFees;
    }

    struct BasketFees {
        uint256 optimalRatio;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 slope0;
        uint256 slope1;
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
        address registry;
        address tokenIn;
        address tokenOut;
        uint256 deadline;
    }
}