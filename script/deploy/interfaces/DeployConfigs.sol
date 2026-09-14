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
    address reserveVault;
}

struct ImplementationsConfig {
    address vault;
    address stablecoin;
    address irm;
    address oracle;
    address registry;
    address floatingMarket;
    address fixedMarket;
    address tranche;
    address underwriter;
    address wrapper;
}

struct InfraConfig {
    address accessManager;
    address vault;
    address stablecoin;
    address irm;
    address oracle;
    address chainlinkAdapter;
    address registry;
    address factory;
    address floatingMarketBeacon;
    address fixedMarketBeacon;
    address trancheBeacon;
    address underwriterBeacon;
    address wrapper;
}
