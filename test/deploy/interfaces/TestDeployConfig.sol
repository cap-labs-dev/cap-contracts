// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ImplementationsConfig,
    InfraConfig,
    LibsConfig,
    UsersConfig,
    VaultConfig
} from "../../../contracts/deploy/interfaces/DeployConfigs.sol";

import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticUsersConfig
} from "../../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

struct TestEnvConfig {
    // non-test specific
    LibsConfig libs;
    ImplementationsConfig implems;
    UsersConfig users;
    InfraConfig infra;
    VaultConfig vault;
    // test specific
    TestUsersConfig testUsers;
    address[] usdMocks;
    OracleMocksConfig oracleMocks;
    address[][] delegationMocks; // [agent][delegator]
    // symbiotic
    SymbioticTestEnvConfig symbiotic;
}

struct SymbioticTestEnvConfig {
    SymbioticUsersConfig users;
    SymbioticNetworkAdapterImplementationsConfig networkAdapterImplems;
    SymbioticNetworkAdapterConfig networkAdapter;
    address[] vaults;
    address[] collaterals;
    address[] burnerRouters;
    address[] globalReceivers;
    address[] delegators;
    address[] slashers;
    address[] networkRewards;
    uint48[] vaultEpochDurations;
}

struct TestUsersConfig {
    address[] agents;
    address stablecoin_minter;
    address liquidator;
}

struct OracleMocksConfig {
    address[] assets;
    address[] aaveDataProviders;
    address[] chainlinkPriceFeeds;
}
