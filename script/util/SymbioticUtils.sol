// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

contract SymbioticUtils {
    enum SlasherType {
        INSTANT,
        VETO
    }

    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }

    struct SymbioticFactories {
        address vaultFactory;
        address delegatorFactory;
        address slasherFactory;
        address defaultStakerRewardsFactory;
        address defaultOperatorRewardsFactory;
        address burnerRouterFactory;
    }

    struct SymbioticRegistries {
        address networkRegistry;
        address vaultRegistry;
        address operatorRegistry;
    }

    struct SymbioticServices {
        address networkMetadataService;
        address networkMiddlewareService;
        address operatorMetadataService;
        address vaultOptInService;
        address networkOptInService;
        address vaultConfigurator;
    }

    struct SymbioticConfig {
        SymbioticFactories factories;
        SymbioticRegistries registries;
        SymbioticServices services;
    }

    function getConfig() public view returns (SymbioticConfig memory config) {
        console.log("block.chainid", block.chainid);
        if (block.chainid == 1) {
            revert("Mainnet not supported");
        } else if (block.chainid == 11155111) {
            // ethereum sepolia
            config.factories.vaultFactory = 0x407A039D94948484D356eFB765b3c74382A050B4;
            config.factories.delegatorFactory = 0x890CA3f95E0f40a79885B7400926544B2214B03f;
            config.factories.slasherFactory = 0xbf34bf75bb779c383267736c53a4ae86ac7bB299;
            config.factories.defaultStakerRewardsFactory = 0x70C618a13D1A57f7234c0b893b9e28C5cA8E7f37;
            config.factories.defaultOperatorRewardsFactory = 0x8D6C873cb7ffa6BE615cE1D55801a9417Ed55f9B;
            config.factories.burnerRouterFactory = 0x32e2AfbdAffB1e675898ABA75868d92eE1E68f3b;
            config.registries.networkRegistry = 0x7d03b7343BF8d5cEC7C0C27ecE084a20113D15C9;
            config.registries.vaultRegistry = 0x407A039D94948484D356eFB765b3c74382A050B4; // == vault registry
            config.registries.operatorRegistry = 0x6F75a4ffF97326A00e52662d82EA4FdE86a2C548;
            config.services.networkMetadataService = 0x0F7E58Cc4eA615E8B8BEB080dF8B8FDB63C21496;
            config.services.networkMiddlewareService = 0x62a1ddfD86b4c1636759d9286D3A0EC722D086e3;
            config.services.operatorMetadataService = 0x0999048aB8eeAfa053bF8581D4Aa451ab45755c9;
            config.services.vaultOptInService = 0x95CC0a052ae33941877c9619835A233D21D57351;
            config.services.networkOptInService = 0x58973d16FFA900D11fC22e5e2B6840d9f7e13401;
            config.services.vaultConfigurator = 0xD2191FE92987171691d552C219b8caEf186eb9cA;
        }
    }

    struct VaultConfig {
        address vault;
        address curator;
        address delegator;
        address slasher;
    }

    function getVaultConfig(address asset) public view returns (VaultConfig memory config) {
        if (block.chainid == 1) {
            revert("Mainnet not supported");
        } else if (block.chainid == 11155111) {
            if (asset == 0xB82381A3fBD3FaFA77B3a7bE693342618240067b) {
                config.vault = 0x77F170Dcd0439c0057055a6D7e5A1Eb9c48cCD2a;
                config.curator = 0xe8616DEcea16b5216e805B0b8caf7784de7570E7;
                config.delegator = 0xB4Dcf89f891E1F825B59880B470e2e6B6B1c2cE9;
                config.slasher = 0x942864Ed10bC8371CfA49aDeF341e2b9EFD1CacA;
            }
        }
    }
}
