// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {
    /// @custom:storage-location erc7201:cap.storage.Lender
    struct LenderStorage {
        mapping(address => ReserveData) reservesData;
        mapping(uint256 => address) reservesList;
        mapping(address => AgentConfigurationMap) agentConfig;
        uint16 reservesCount;
        address delegation;
        address oracle;
        mapping(address => address) restakerInterestReceiver;
        mapping(address => uint256) liquidationStart;
        uint256 targetHealth;
        uint256 grace;
        uint256 expiry;
        uint256 bonusCap;
    }

    struct ReserveData {
        uint256 id;
        address vault;
        address principalDebtToken;
        address restakerDebtToken;
        address interestDebtToken;
        address interestReceiver;
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
    }
}
