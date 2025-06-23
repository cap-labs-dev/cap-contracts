// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { VaultConfig, VaultLzPeriphery } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { TokenSerializer } from "./TokenSerializer.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract VaultConfigSerializer is TokenSerializer {
    using stdJson for string;

    function _capVaultsFilePath() private view returns (string memory) {
        return _capVaultsFilePath(block.chainid);
    }

    function _capVaultsFilePath(uint256 srcChainId) private view returns (string memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return string.concat(vm.projectRoot(), "/config/cap-vaults-", Strings.toString(srcChainId), ".json");
    }

    function _saveVaultConfig(VaultConfig memory vault) internal {
        string memory vaultJson = "vault";

        string[] memory assetsJson = new string[](vault.assets.length);
        for (uint256 i = 0; i < vault.assets.length; i++) {
            string memory assetJson = string.concat("assets[", Strings.toString(i), "]");
            assetJson = assetJson.serialize("asset", _serializeToken(vault.assets[i]));
            console.log(assetJson);
            assetsJson[i] = assetJson;
        }
        string[] memory debtTokensJson = new string[](vault.debtTokens.length);
        for (uint256 i = 0; i < vault.debtTokens.length; i++) {
            string memory debtTokenJson = string.concat("debtTokens[", Strings.toString(i), "]");
            debtTokenJson = debtTokenJson.serialize("debtToken", _serializeToken(vault.debtTokens[i]));
            debtTokensJson[i] = debtTokenJson;
        }

        vaultJson.serialize("assets", assetsJson);
        vaultJson.serialize("debtTokens", debtTokensJson);
        vaultJson.serialize("capToken", _serializeToken(vault.capToken));
        vaultJson.serialize("stakedCapToken", _serializeToken(vault.stakedCapToken));
        vaultJson.serialize("feeAuction", vault.feeAuction);
        vaultJson.serialize("capOFTLockbox", vault.lzperiphery.capOFTLockbox);
        vaultJson.serialize("capZapComposer", vault.lzperiphery.capZapComposer);
        vaultJson.serialize("stakedCapOFTLockbox", vault.lzperiphery.stakedCapOFTLockbox);
        vaultJson = vaultJson.serialize("stakedCapZapComposer", vault.lzperiphery.stakedCapZapComposer);
        console.log(vaultJson);

        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory previousJson = vm.readFile(_capVaultsFilePath());
        string memory capTokenSymbol = IERC20Metadata(vault.capToken).symbol();
        string memory mergedJson = "merged";
        mergedJson.serialize(previousJson);
        mergedJson = mergedJson.serialize(capTokenSymbol, vaultJson);
        vm.writeFile(_capVaultsFilePath(), mergedJson);
    }

    function _readVaultConfig(string memory srcCapToken) internal view returns (VaultConfig memory vault) {
        return _readVaultConfig(block.chainid, srcCapToken);
    }

    function _readVaultConfig(string memory srcChainId, string memory srcCapToken)
        internal
        view
        returns (VaultConfig memory vault)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return _readVaultConfig(vm.parseUint(srcChainId), srcCapToken);
    }

    function _readVaultConfig(uint256 srcChainId, string memory srcCapToken)
        internal
        view
        returns (VaultConfig memory vault)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory json = vm.readFile(_capVaultsFilePath(srcChainId));
        string memory tokenPrefix = string.concat("$.", srcCapToken, ".");

        // FIXME: .length() doesn't seem to work
        //        https://crates.io/crates/jsonpath-rust

        address[] memory assets = new address[](100);
        uint256 count = 0;
        for (; count < 100; count++) {
            string memory prefix = string.concat(tokenPrefix, "assets[", Strings.toString(count), "].");
            address asset = json.readAddressOr(string.concat(prefix, "asset.address"), address(0));
            if (asset == address(0)) {
                break;
            }
            assets[count] = asset;
        }
        address[] memory trueAssets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            trueAssets[i] = assets[i];
        }

        address[] memory debtTokens = new address[](100);
        count = 0;
        for (; count < 100; count++) {
            string memory prefix = string.concat(tokenPrefix, "debtTokens[", Strings.toString(count), "].");
            address debtToken = json.readAddressOr(string.concat(prefix, "debtToken.address"), address(0));
            if (debtToken == address(0)) {
                break;
            }
            debtTokens[count] = debtToken;
        }
        address[] memory trueDebtTokens = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            trueDebtTokens[i] = debtTokens[i];
        }

        vault = VaultConfig({
            capToken: json.readAddress(string.concat(tokenPrefix, "['capToken'].address")),
            stakedCapToken: json.readAddress(string.concat(tokenPrefix, "['stakedCapToken'].address")),
            feeAuction: json.readAddress(string.concat(tokenPrefix, "feeAuction")),
            feeReceiver: json.readAddress(string.concat(tokenPrefix, "feeReceiver")),
            lzperiphery: VaultLzPeriphery({
                capOFTLockbox: json.readAddress(string.concat(tokenPrefix, "capOFTLockbox")),
                stakedCapOFTLockbox: json.readAddress(string.concat(tokenPrefix, "stakedCapOFTLockbox")),
                capZapComposer: json.readAddress(string.concat(tokenPrefix, "capZapComposer")),
                stakedCapZapComposer: json.readAddress(string.concat(tokenPrefix, "stakedCapZapComposer"))
            }),
            assets: trueAssets,
            debtTokens: trueDebtTokens
        });
    }
}
