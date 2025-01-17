// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {
    struct ReserveData {
        uint256 id;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        address interestReceiver;
        uint8 decimals;
        uint256 bonusCap;
        bool paused;
        uint256 realizedInterest;
    }

    struct AgentConfigurationMap {
        uint256 data;
    }

    struct BorrowParams {
        uint256 id;
        address agent;
        address asset;
        uint8 decimals;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        uint256 amount;
        address receiver;
        address delegation;
        address oracle;
        uint16 reserveCount;
    }

    struct RepayParams {
        uint256 id;
        address agent;
        address asset;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        uint256 amount;
        address caller;
        uint256 realizedInterest;
        address restakerInterestReceiver;
        address interestReceiver;
    }

    struct RealizeInterestParams {
        address asset;
        address vault;
        address interestDebtToken;
        address interestReceiver;
        uint256 amount;
        uint256 realizedInterest;
    }

    struct InitiateLiquidationParams {
        address agent;
        address delegation;
        address oracle;
        uint16 reserveCount;
        uint256 expiry;
    }

    struct LiquidateParams {
        uint256 id;
        address agent;
        address asset;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        uint256 amount;
        uint8 decimals;
        address caller;
        uint256 realizedInterest;
        address delegation;
        address oracle;
        uint16 reserveCount;
        address restakerInterestReceiver;
        address interestReceiver;
        uint256 bonusCap;
        uint256 targetHealth;
        uint256 start;
        uint256 grace;
        uint256 expiry;
    }

    struct AgentParams {
        address agent;
        address delegation;
        address oracle;
        uint16 reserveCount;
    }

    struct AddAssetParams {
        address asset;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        address interestReceiver;
        uint8 decimals;
        uint256 bonusCap;
        uint16 reserveCount;
    }

    struct ValidateBorrowParams {
        address agent;
        address asset;
        uint8 decimals;
        uint256 amount;
        address delegation;
        address oracle;
        uint16 reserveCount;
    }

    struct ValidateAddAssetParams {
        address asset;
        address vault;
        uint16 reserveCount;
    }
}
