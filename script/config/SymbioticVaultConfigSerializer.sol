// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract SymbioticVaultConfigSerializer {
    using stdJson for string;

    function _symbioticVaultsFilePath() private view returns (string memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return
            string.concat(vm.projectRoot(), "/config/cap-symbiotic-vaults-", Strings.toString(block.chainid), ".json");
    }

    function _saveSymbioticVaultConfig(SymbioticVaultConfig memory vault, SymbioticNetworkRewardsConfig memory rewards)
        internal
    {
        string memory vaultJson = "vault";
        vaultJson.serialize("vault", vault.vault);
        vaultJson.serialize("collateral", vault.collateral);
        vaultJson.serialize("burnerRouter", vault.burnerRouter);
        vaultJson.serialize("globalReceiver", vault.globalReceiver);
        vaultJson.serialize("delegator", vault.delegator);
        vaultJson.serialize("slasher", vault.slasher);
        vaultJson.serialize("vaultEpochDuration", vault.vaultEpochDuration);
        vaultJson = vaultJson.serialize("stakerRewarder", rewards.stakerRewarder);

        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory previousJson = vm.readFile(_symbioticVaultsFilePath());
        string memory mergedJson = "merged";
        mergedJson.serialize(previousJson);
        mergedJson = mergedJson.serialize(Strings.toHexString(vault.vault), vaultJson);
        vm.writeFile(_symbioticVaultsFilePath(), mergedJson);
    }

    function _readSymbioticVaultConfig(address vaultAddress)
        internal
        view
        returns (SymbioticVaultConfig memory vault, SymbioticNetworkRewardsConfig memory rewards)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory json = vm.readFile(_symbioticVaultsFilePath());
        string memory vaultPrefix = string.concat("$['", Strings.toHexString(vaultAddress), "'].");

        vault = SymbioticVaultConfig({
            vault: json.readAddress(string.concat(vaultPrefix, "vault")),
            collateral: json.readAddress(string.concat(vaultPrefix, "collateral")),
            burnerRouter: json.readAddress(string.concat(vaultPrefix, "burnerRouter")),
            globalReceiver: json.readAddress(string.concat(vaultPrefix, "globalReceiver")),
            delegator: json.readAddress(string.concat(vaultPrefix, "delegator")),
            slasher: json.readAddress(string.concat(vaultPrefix, "slasher")),
            vaultEpochDuration: uint48(json.readUint(string.concat(vaultPrefix, "vaultEpochDuration")))
        });

        rewards = SymbioticNetworkRewardsConfig({
            stakerRewarder: json.readAddress(string.concat(vaultPrefix, "stakerRewarder"))
        });
    }
}
