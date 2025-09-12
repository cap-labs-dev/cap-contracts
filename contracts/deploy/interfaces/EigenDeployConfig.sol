// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

struct EigenImplementationsConfig {
    address eigenServiceManager;
    address agentManager;
}

struct EigenConfig {
    address eigenServiceManager;
    address agentManager;
    uint256 rewardDuration;
}

struct EigenUsersConfig {
    address strategy_admin;
}

struct EigenVaultParams {
    address strategy_admin;
    address collateral;
    address agent;
}

struct EigenVaultConfig {
    address strategy;
    address collateral;
    address agent;
}
