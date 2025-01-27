// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct LibsConfig {
    address aaveAdapter;
    address chainlinkAdapter;
    address capTokenAdapter;
    address stakedCapAdapter;
}

struct ImplementationsConfig {
    address accessControl;
    address lender;
    address delegation;
    address capToken;
    address stakedCap;
    address oracle;
    address principalDebtToken;
    address interestDebtToken;
    address restakerDebtToken;
}

struct InfraConfig {
    address oracle;
    address accessControl;
    address lender;
    address delegation;
}

struct UsersConfig {
    address deployer;
    address delegation_admin;
    address oracle_admin;
    address lender_admin;
    address access_control_admin;
    address address_provider_admin;
    address interest_receiver;
    address vault_keeper;
    address rate_oracle_admin;
    address vault_config_admin;
}

struct VaultConfig {
    address capToken; // also called the vault
    address stakedCapToken;
    address[] assets;
    address[] principalDebtTokens;
    address[] restakerDebtTokens;
    address[] interestDebtTokens;
}
