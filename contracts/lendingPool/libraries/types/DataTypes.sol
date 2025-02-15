// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library DataTypes {
    struct ReserveData {
        uint256 id;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        address interestReceiver;
        address restakerInterestReceiver;
        uint8 decimals;
        bool paused;
        uint256 realizedInterest;
    }

    struct AgentConfigurationMap {
        uint256 data;
    }

    struct BorrowParams {
        address agent;
        address asset;
        uint256 amount;
        address receiver;
    }

    struct RepayParams {
        address agent;
        address asset;
        uint256 amount;
        address caller;
    }

    struct RealizeInterestParams {
        address asset;
        uint256 amount;
    }

    struct AddAssetParams {
        address asset;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        address interestReceiver;
        address restakerInterestReceiver;
        uint256 bonusCap;
    }
}
