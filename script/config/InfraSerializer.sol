// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ImplementationsConfig, InfraConfig } from "../deploy/interfaces/DeployConfigs.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";

/// @title InfraSerializer
/// @notice Read and write `config/cap-v2.json`, keyed by chain id
/// @dev Role membership is not stored here. AccessManager holds that, and a role can have many members.
abstract contract InfraSerializer {
    using stdJson for string;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Persist implementations and infra. Leaves `deployer` and token config as they are.
    /// @param implems The implementation addresses
    /// @param infra The deployed infrastructure addresses
    function _saveInfra(ImplementationsConfig memory implems, InfraConfig memory infra) internal {
        string memory json = VM.readFile(_infraPath());
        string memory prefix = _chainPrefix();

        string memory implemsJson = "implems";
        implemsJson.serialize("vault", implems.vault);
        implemsJson.serialize("stablecoin", implems.stablecoin);
        implemsJson.serialize("irm", implems.irm);
        implemsJson.serialize("oracle", implems.oracle);
        implemsJson.serialize("registry", implems.registry);
        implemsJson.serialize("floatingMarket", implems.floatingMarket);
        implemsJson.serialize("fixedMarket", implems.fixedMarket);
        implemsJson.serialize("tranche", implems.tranche);
        implemsJson.serialize("underwriter", implems.underwriter);
        implemsJson = implemsJson.serialize("wrapper", implems.wrapper);

        string memory infraJson = "infra";
        infraJson.serialize("accessManager", infra.accessManager);
        infraJson.serialize("vault", infra.vault);
        infraJson.serialize("stablecoin", infra.stablecoin);
        infraJson.serialize("irm", infra.irm);
        infraJson.serialize("oracle", infra.oracle);
        infraJson.serialize("chainlinkAdapter", infra.chainlinkAdapter);
        infraJson.serialize("registry", infra.registry);
        infraJson.serialize("factory", infra.factory);
        infraJson.serialize("floatingMarketBeacon", infra.floatingMarketBeacon);
        infraJson.serialize("fixedMarketBeacon", infra.fixedMarketBeacon);
        infraJson.serialize("trancheBeacon", infra.trancheBeacon);
        infraJson.serialize("underwriterBeacon", infra.underwriterBeacon);
        infraJson = infraJson.serialize("wrapper", infra.wrapper);

        string memory chainJson = "chain";
        chainJson.serialize("deployer", json.readAddress(string.concat(prefix, "deployer")));
        chainJson.serialize("timelock", json.readAddress(string.concat(prefix, "timelock")));
        chainJson.serialize("multisig", json.readAddress(string.concat(prefix, "multisig")));
        chainJson.serialize("stablecoinUnderlying", json.readAddress(string.concat(prefix, "stablecoinUnderlying")));
        chainJson.serialize("reserveVault", json.readAddress(string.concat(prefix, "reserveVault")));
        chainJson.serialize("implems", implemsJson);
        chainJson = chainJson.serialize("infra", infraJson);

        string memory previous = VM.exists(_infraPath()) ? VM.readFile(_infraPath()) : "{}";
        string memory merged = "merged";
        merged.serialize(previous);
        merged = merged.serialize(Strings.toString(block.chainid), chainJson);
        VM.writeFile(_infraPath(), merged);
    }

    /// @dev Load the last saved deployment for this chain
    /// @return implems The implementation addresses
    /// @return infra The deployed infrastructure addresses
    function _readInfra() internal view returns (ImplementationsConfig memory implems, InfraConfig memory infra) {
        string memory json = VM.readFile(_infraPath());
        string memory prefix = _chainPrefix();

        string memory implemsPrefix = string.concat(prefix, "implems.");
        implems = ImplementationsConfig({
            vault: json.readAddress(string.concat(implemsPrefix, "vault")),
            stablecoin: json.readAddress(string.concat(implemsPrefix, "stablecoin")),
            irm: json.readAddress(string.concat(implemsPrefix, "irm")),
            oracle: json.readAddress(string.concat(implemsPrefix, "oracle")),
            registry: json.readAddress(string.concat(implemsPrefix, "registry")),
            floatingMarket: json.readAddress(string.concat(implemsPrefix, "floatingMarket")),
            fixedMarket: json.readAddress(string.concat(implemsPrefix, "fixedMarket")),
            tranche: json.readAddress(string.concat(implemsPrefix, "tranche")),
            underwriter: json.readAddress(string.concat(implemsPrefix, "underwriter")),
            wrapper: json.readAddress(string.concat(implemsPrefix, "wrapper"))
        });

        string memory infraPrefix = string.concat(prefix, "infra.");
        infra = InfraConfig({
            accessManager: json.readAddress(string.concat(infraPrefix, "accessManager")),
            vault: json.readAddress(string.concat(infraPrefix, "vault")),
            stablecoin: json.readAddress(string.concat(infraPrefix, "stablecoin")),
            irm: json.readAddress(string.concat(infraPrefix, "irm")),
            oracle: json.readAddress(string.concat(infraPrefix, "oracle")),
            chainlinkAdapter: json.readAddress(string.concat(infraPrefix, "chainlinkAdapter")),
            registry: json.readAddress(string.concat(infraPrefix, "registry")),
            factory: json.readAddress(string.concat(infraPrefix, "factory")),
            floatingMarketBeacon: json.readAddress(string.concat(infraPrefix, "floatingMarketBeacon")),
            fixedMarketBeacon: json.readAddress(string.concat(infraPrefix, "fixedMarketBeacon")),
            trancheBeacon: json.readAddress(string.concat(infraPrefix, "trancheBeacon")),
            underwriterBeacon: json.readAddress(string.concat(infraPrefix, "underwriterBeacon")),
            wrapper: json.readAddress(string.concat(infraPrefix, "wrapper"))
        });
    }

    /// @dev The account that broadcasts CreateX deploys for this chain
    function _readDeployer() internal view returns (address deployer) {
        deployer = _readAccount("deployer");
    }

    /// @dev Named account stored next to the deployment, not as a role holder
    function _readAccount(string memory key) internal view returns (address account) {
        account = VM.readFile(_infraPath()).readAddress(string.concat(_chainPrefix(), key));
    }

    function _chainPrefix() private view returns (string memory prefix) {
        prefix = string.concat("$['", Strings.toString(block.chainid), "'].");
    }

    function _infraPath() private view returns (string memory path) {
        path = string.concat(VM.projectRoot(), "/config/cap-v2.json");
    }
}
