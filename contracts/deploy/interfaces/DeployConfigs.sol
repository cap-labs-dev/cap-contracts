// SPDX-License-Identifier: BUSL-1.1
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
    address debtToken;
    address feeAuction;
    address feeReceiver;
    address chainlinkPoRAddressList;
    address wrapper;
}

struct InfraConfig {
    address oracle;
    address accessControl;
    address lender;
    address delegation;
    address chainlinkPoRAddressList;
    address gelatoHarvester;
    address gelatoSweeper;
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
    address fee_auction_admin;
    address access_control_admin;
    address address_provider_admin;
    address rate_oracle_admin;
    address vault_config_admin;
    address middleware_admin;
    address staker_rewards_admin;
    address insurance_fund;
    address strategy_admin;
}

struct EigenAddresses {
    address eigenServiceManager;
    address agentManager;
}

struct VaultConfig {
    address capToken; // also called the vault
    address stakedCapToken;
    address feeAuction;
    address feeReceiver;
    VaultLzPeriphery lzperiphery;
    address[] assets;
    address[] debtTokens;
}

struct VaultLzPeriphery {
    address capOFTLockbox;
    address stakedCapOFTLockbox;
    address capZapComposer;
    address stakedCapZapComposer;
}

struct FeeConfig {
    uint256 minMintFee;
    uint256 slope0;
    uint256 slope1;
    uint256 mintKinkRatio;
    uint256 burnKinkRatio;
    uint256 optimalRatio;
}
