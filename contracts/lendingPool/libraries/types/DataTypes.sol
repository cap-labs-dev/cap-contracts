// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {

    struct ReserveData {
        uint256 id;
        address vault;
        address debtToken;
        uint256 bonus;
        bool paused;
    }

    struct AgentConfigurationMap {
        uint256 data;
    }

    struct BorrowParams {
        uint256 id;
        address agent;
        address asset;
        address vault;
        address debtToken;
        uint256 amount;
        address receiver;
        address collateral;
        address oracle;
        uint16 reserveCount;
    }

    struct RepayParams {
        uint256 id;
        address agent;
        address asset;
        address vault;
        address debtToken;
        uint256 amount;
        uint256 interest;
        address caller;
        address restakerRewarder;
        address rewarder;
    }

    struct LiquidateParams {
        uint256 id;
        address agent;
        address asset;
        address vault;
        address debtToken;
        uint256 bonus;
        uint256 amount;
        uint256 interest;
        address caller;
        address collateral;
        address oracle;
        uint16 reserveCount;
        address restakerRewarder;
        address rewarder;
    }

    struct AgentParams {
        address agent;
        address collateral;
        address oracle;
        uint16 reserveCount;
    }

    struct AddAssetParams {
        address asset;
        address vault;
        address debtTokenInstance;
        uint256 bonus;
        uint16 reserveCount;
    }

    struct ValidateBorrowParams {
        address agent;
        address asset;
        uint256 amount;
        address collateral;
        address oracle;
        uint16 reserveCount;
    }

    struct ValidateAddAssetParams {
        address asset;
        address vault;
        uint16 reserveCount;
    }
}