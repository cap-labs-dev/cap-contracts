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

struct PreMainnetImplementationsConfig {
    address preMainnetVault;
}

struct InfraConfig {
    address oracle;
    address accessControl;
    address lender;
    address delegation;
}

struct PreMainnetInfraConfig {
    address preMainnetVault;
}

struct L2VaultConfig {
    address bridgedCapToken;
    address bridgedStakedCapToken;
}

struct UsersConfig {
    address deployer;
    address delegation_admin;
    address oracle_admin;
    address lender_admin;
    address access_control_admin;
    address address_provider_admin;
    address interest_receiver;
    address rate_oracle_admin;
    address vault_config_admin;
    address middleware_admin;
    address staker_rewards_admin;
}

struct VaultConfig {
    address capToken; // also called the vault
    address stakedCapToken;
    address capOFTLockbox;
    address stakedCapOFTLockbox;
    address capZapComposer;
    address stakedCapZapComposer;
    address[] assets;
    address[] principalDebtTokens;
    address[] restakerDebtTokens;
    address[] interestDebtTokens;
}
