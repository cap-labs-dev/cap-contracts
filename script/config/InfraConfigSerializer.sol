// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ImplementationsConfig, InfraConfig, LibsConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract InfraConfigSerializer {
    using stdJson for string;

    function _capInfraFilePath() private view returns (string memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return string.concat(vm.projectRoot(), "/config/cap-infra.json");
    }

    function _saveInfraConfig(ImplementationsConfig memory implems, LibsConfig memory libs, InfraConfig memory infra)
        internal
    {
        string memory implemsJson = "implems";
        implemsJson.serialize("vault", implems.vault);
        implemsJson.serialize("stablecoin", implems.stablecoin);
        implemsJson.serialize("irm", implems.irm);
        implemsJson.serialize("registry", implems.registry);
        implemsJson.serialize("floatingMarket", implems.floatingMarket);
        implemsJson.serialize("fixedMarket", implems.fixedMarket);
        implemsJson.serialize("tranche", implems.tranche);
        implemsJson = implemsJson.serialize("underwriter", implems.underwriter);
        console.log(implemsJson);

        string memory libsJson = "libs";
        libsJson = libsJson.serialize("unused", libs.unused);
        console.log(libsJson);

        string memory infraJson = "infra";
        infraJson.serialize("accessManager", infra.accessManager);
        infraJson.serialize("vault", infra.vault);
        infraJson.serialize("stablecoin", infra.stablecoin);
        infraJson.serialize("irm", infra.irm);
        infraJson.serialize("registry", infra.registry);
        infraJson.serialize("factory", infra.factory);
        infraJson.serialize("floatingMarketBeacon", infra.floatingMarketBeacon);
        infraJson.serialize("fixedMarketBeacon", infra.fixedMarketBeacon);
        infraJson.serialize("trancheBeacon", infra.trancheBeacon);
        infraJson = infraJson.serialize("underwriterBeacon", infra.underwriterBeacon);
        console.log(infraJson);

        string memory chainJson = "chain";
        chainJson.serialize("implems", implemsJson);
        chainJson.serialize("libs", libsJson);
        chainJson = chainJson.serialize("infra", infraJson);
        console.log(chainJson);

        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory previousJson = vm.readFile(_capInfraFilePath());
        string memory mergedJson = "merged";
        mergedJson.serialize(previousJson);
        mergedJson = mergedJson.serialize(Strings.toString(block.chainid), chainJson);
        vm.writeFile(_capInfraFilePath(), mergedJson);
    }

    function _readInfraConfig()
        internal
        view
        returns (ImplementationsConfig memory implems, LibsConfig memory libs, InfraConfig memory infra)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory json = vm.readFile(_capInfraFilePath());
        string memory chainPrefix = string.concat("$['", Strings.toString(block.chainid), "'].");

        string memory implemsPrefix = string.concat(chainPrefix, "implems.");
        implems = ImplementationsConfig({
            vault: json.readAddress(string.concat(implemsPrefix, "vault")),
            stablecoin: json.readAddress(string.concat(implemsPrefix, "stablecoin")),
            irm: json.readAddress(string.concat(implemsPrefix, "irm")),
            registry: json.readAddress(string.concat(implemsPrefix, "registry")),
            floatingMarket: json.readAddress(string.concat(implemsPrefix, "floatingMarket")),
            fixedMarket: json.readAddress(string.concat(implemsPrefix, "fixedMarket")),
            tranche: json.readAddress(string.concat(implemsPrefix, "tranche")),
            underwriter: json.readAddress(string.concat(implemsPrefix, "underwriter"))
        });

        string memory libsPrefix = string.concat(chainPrefix, "libs.");
        libs = LibsConfig({ unused: json.readAddress(string.concat(libsPrefix, "unused")) });

        string memory infraPrefix = string.concat(chainPrefix, "infra.");
        infra = InfraConfig({
            accessManager: json.readAddress(string.concat(infraPrefix, "accessManager")),
            vault: json.readAddress(string.concat(infraPrefix, "vault")),
            stablecoin: json.readAddress(string.concat(infraPrefix, "stablecoin")),
            irm: json.readAddress(string.concat(infraPrefix, "irm")),
            registry: json.readAddress(string.concat(infraPrefix, "registry")),
            factory: json.readAddress(string.concat(infraPrefix, "factory")),
            floatingMarketBeacon: json.readAddress(string.concat(infraPrefix, "floatingMarketBeacon")),
            fixedMarketBeacon: json.readAddress(string.concat(infraPrefix, "fixedMarketBeacon")),
            trancheBeacon: json.readAddress(string.concat(infraPrefix, "trancheBeacon")),
            underwriterBeacon: json.readAddress(string.concat(infraPrefix, "underwriterBeacon"))
        });
    }
}
