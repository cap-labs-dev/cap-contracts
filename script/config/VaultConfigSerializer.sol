// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract VaultConfigSerializer {
    using stdJson for string;

    function _capVaultsFilePath() private view returns (string memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return string.concat(vm.projectRoot(), "/config/cap-vaults-", Strings.toString(block.chainid), ".json");
    }

    function _serializeToken(address token) internal returns (string memory) {
        string memory symbol = IERC20Metadata(token).symbol();
        uint256 decimals = IERC20Metadata(token).decimals();
        string memory json = string.concat("token_", symbol);
        json.serialize("symbol", symbol);
        json.serialize("decimals", decimals);
        json = json.serialize("address", token);
        console.log(json);
        return json;
    }

    function _saveVaultConfig(VaultConfig memory vault) internal {
        string memory vaultJson = "vault";

        string[] memory assetsJson = new string[](vault.assets.length);
        for (uint256 i = 0; i < vault.assets.length; i++) {
            string memory assetJson = string.concat("assets[", Strings.toString(i), "]");
            assetJson.serialize("asset", _serializeToken(vault.assets[i]));
            assetJson.serialize("principalDebtToken", _serializeToken(vault.principalDebtTokens[i]));
            assetJson.serialize("restakerDebtToken", _serializeToken(vault.restakerDebtTokens[i]));
            assetJson = assetJson.serialize("interestDebtToken", _serializeToken(vault.interestDebtTokens[i]));
            console.log(assetJson);
            assetsJson[i] = assetJson;
        }

        vaultJson.serialize("assets", assetsJson);
        vaultJson.serialize("capToken", _serializeToken(vault.capToken));
        vaultJson.serialize("capOFTLockbox", vault.capOFTLockbox);
        vaultJson.serialize("stakedCapToken", _serializeToken(vault.stakedCapToken));
        vaultJson = vaultJson.serialize("stakedCapOFTLockbox", vault.stakedCapOFTLockbox);
        console.log(vaultJson);

        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory previousJson = vm.readFile(_capVaultsFilePath());
        string memory capTokenSymbol = IERC20Metadata(vault.capToken).symbol();
        string memory mergedJson = "merged";
        mergedJson.serialize(previousJson);
        mergedJson = mergedJson.serialize(capTokenSymbol, vaultJson);
        vm.writeFile(_capVaultsFilePath(), mergedJson);
    }

    function _readVaultConfig(string memory vaultKey) internal view returns (VaultConfig memory vault) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory json = vm.readFile(_capVaultsFilePath());
        string memory vaultJson = json.readString(string.concat(Strings.toString(block.chainid), vaultKey));

        address[] memory assets = new address[](vaultJson.readUint("assets.length"));

        vault = VaultConfig({
            capToken: vaultJson.readAddress("capToken"),
            stakedCapToken: vaultJson.readAddress("stakedCapToken"),
            capOFTLockbox: vaultJson.readAddress("capOFTLockbox"),
            stakedCapOFTLockbox: vaultJson.readAddress("stakedCapOFTLockbox"),
            assets: assets,
            principalDebtTokens: vaultJson.readAddressArray("principalDebtTokens"),
            restakerDebtTokens: vaultJson.readAddressArray("restakerDebtTokens"),
            interestDebtTokens: vaultJson.readAddressArray("interestDebtTokens")
        });
    }
}
