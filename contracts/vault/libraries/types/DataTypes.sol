// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library DataTypes {
    /// @custom:storage-location erc7201:cap.storage.Vault
    struct VaultStorage {
        address[] assets;
        mapping(address => uint256) totalSupplies;
        mapping(address => uint256) totalBorrows;
        mapping(address => uint256) utilizationIndex;
        mapping(address => uint256) lastUpdate;
        mapping(address => bool) paused;
    }

    /// @custom:storage-location erc7201:cap.storage.Minter
    struct MinterStorage {
        address oracle;
        uint256 redeemFee;
        mapping(address => FeeData) fees;
    }

    struct MintBurnParams {
        address asset;
        uint256 amountIn;
        uint256 amountOut;
        uint256 minAmountOut;
        address receiver;
        uint256 deadline;
    }

    struct RedeemParams {
        uint256 amountIn;
        uint256[] amountsOut;
        uint256[] minAmountsOut;
        address receiver;
        uint256 deadline;
    }

    struct BorrowParams {
        address asset;
        uint256 amount;
        address receiver;
    }

    struct RepayParams {
        address asset;
        uint256 amount;
    }

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
    }

    struct RedeemAmountOutParams {
        uint256 amount;
    }

    struct FeeSlopeParams {
        bool mint;
        uint256 amount;
        uint256 ratio;
    }
}
