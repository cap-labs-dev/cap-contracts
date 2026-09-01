// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

struct UsersConfig {
    address deployer;
    address governor;
    address keeper;
    address guardian;
    address admin;
    address liquidator;
    address stablecoinUnderlying;
    address stakedStablecoin;
}

struct ImplementationsConfig {
    address vault;
    address stablecoin;
    address irm;
    address registry;
    address floatingMarket;
    address fixedMarket;
    address tranche;
    address underwriter;
}

struct LibsConfig {
    address unused;
}

struct InfraConfig {
    address accessManager;
    address vault;
    address stablecoin;
    address irm;
    address registry;
    address factory;
    address floatingMarketBeacon;
    address fixedMarketBeacon;
    address trancheBeacon;
    address underwriterBeacon;
}

struct VaultConfig {
    address capToken;
    address stakedCapToken;
}

struct FeeConfig {
    address feeReceiver;
}
