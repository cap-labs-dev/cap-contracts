// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract SymbioticUtils {
    using stdJson for string;

    string public constant CONFIG_PATH_FROM_PROJECT_ROOT = "config/symbiotic.json";

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
        Vm vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

        string memory configJson = vm.readFile(CONFIG_PATH_FROM_PROJECT_ROOT);
        string memory selectorPrefix = string.concat("$['", vm.toString(block.chainid), "']");

        console.log("block.chainid", block.chainid);

        // ethereum sepolia
        config.factories.vaultFactory = configJson.readAddress(string.concat(selectorPrefix, ".factories.vaultFactory"));
        config.factories.delegatorFactory =
            configJson.readAddress(string.concat(selectorPrefix, ".factories.delegatorFactory"));
        config.factories.slasherFactory =
            configJson.readAddress(string.concat(selectorPrefix, ".factories.slasherFactory"));
        config.factories.defaultStakerRewardsFactory =
            configJson.readAddress(string.concat(selectorPrefix, ".factories.defaultStakerRewardsFactory"));
        config.factories.defaultOperatorRewardsFactory =
            configJson.readAddress(string.concat(selectorPrefix, ".factories.defaultOperatorRewardsFactory"));
        config.factories.burnerRouterFactory =
            configJson.readAddress(string.concat(selectorPrefix, ".factories.burnerRouterFactory"));

        config.registries.networkRegistry =
            configJson.readAddress(string.concat(selectorPrefix, ".registries.networkRegistry"));
        config.registries.vaultRegistry =
            configJson.readAddress(string.concat(selectorPrefix, ".registries.vaultRegistry"));
        config.registries.operatorRegistry =
            configJson.readAddress(string.concat(selectorPrefix, ".registries.operatorRegistry"));

        config.services.networkMetadataService =
            configJson.readAddress(string.concat(selectorPrefix, ".services.networkMetadataService"));
        config.services.networkMiddlewareService =
            configJson.readAddress(string.concat(selectorPrefix, ".services.networkMiddlewareService"));
        config.services.operatorMetadataService =
            configJson.readAddress(string.concat(selectorPrefix, ".services.operatorMetadataService"));
        config.services.vaultOptInService =
            configJson.readAddress(string.concat(selectorPrefix, ".services.vaultOptInService"));
        config.services.networkOptInService =
            configJson.readAddress(string.concat(selectorPrefix, ".services.networkOptInService"));
        config.services.vaultConfigurator =
            configJson.readAddress(string.concat(selectorPrefix, ".services.vaultConfigurator"));
    }

    struct VaultConfig {
        address vault;
        address curator;
        address delegator;
        address slasher;
    }

    function getVaultConfig(address asset) public view returns (VaultConfig memory config) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        string memory configJson = vm.readFile(CONFIG_PATH_FROM_PROJECT_ROOT);
        string memory selectorPrefix =
            string.concat("$['", vm.toString(block.chainid), "'].vaults[", vm.toString(asset), "]");

        config.vault = configJson.readAddress(string.concat(selectorPrefix, ".vault"));
        config.curator = configJson.readAddress(string.concat(selectorPrefix, ".curator"));
        config.delegator = configJson.readAddress(string.concat(selectorPrefix, ".delegator"));
        config.slasher = configJson.readAddress(string.concat(selectorPrefix, ".slasher"));
    }
}
