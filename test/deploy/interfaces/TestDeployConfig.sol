// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig,
    VaultConfig
} from "../../../contracts/deploy/interfaces/DeployConfigs.sol";

struct TestEnvConfig {
    // non-test specific
    LibsConfig libs;
    ImplementationsConfig implems;
    UsersConfig users;
    InfraConfig infra;
    VaultConfig vault;
    // test specific
    TestUsersConfig testUsers;
    OracleMocksConfig oracleMocks;
    DelegationMockConfig delegationMock;
}

struct TestUsersConfig {
    address agent;
    address stablecoin_minter;
    address liquidator;
}

struct OracleMocksConfig {
    address[] assets;
    address[] aaveDataProviders;
    address[] chainlinkPriceFeeds;
}

struct DelegationMockConfig {
    address[] delegators;
}
