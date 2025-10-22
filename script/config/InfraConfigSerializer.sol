// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        implemsJson.serialize("accessControl", implems.accessControl);
        implemsJson.serialize("lender", implems.lender);
        implemsJson.serialize("delegation", implems.delegation);
        implemsJson.serialize("capToken", implems.capToken);
        implemsJson.serialize("stakedCap", implems.stakedCap);
        implemsJson.serialize("oracle", implems.oracle);
        implemsJson.serialize("debtToken", implems.debtToken);
        implemsJson.serialize("feeAuction", implems.feeAuction);
        implemsJson.serialize("wrapper", implems.wrapper);
        implemsJson = implemsJson.serialize("feeReceiver", implems.feeReceiver);
        console.log(implemsJson);

        string memory libsJson = "libs";
        libsJson.serialize("aaveAdapter", libs.aaveAdapter);
        libsJson.serialize("chainlinkAdapter", libs.chainlinkAdapter);
        libsJson.serialize("capTokenAdapter", libs.capTokenAdapter);
        libsJson = libsJson.serialize("stakedCapAdapter", libs.stakedCapAdapter);
        console.log(libsJson);

        string memory infraJson = "infra";
        infraJson.serialize("oracle", infra.oracle);
        infraJson.serialize("accessControl", infra.accessControl);
        infraJson.serialize("lender", infra.lender);
        infraJson = infraJson.serialize("delegation", infra.delegation);
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
            accessControl: json.readAddress(string.concat(implemsPrefix, "accessControl")),
            lender: json.readAddress(string.concat(implemsPrefix, "lender")),
            delegation: json.readAddress(string.concat(implemsPrefix, "delegation")),
            capToken: json.readAddress(string.concat(implemsPrefix, "capToken")),
            stakedCap: json.readAddress(string.concat(implemsPrefix, "stakedCap")),
            oracle: json.readAddress(string.concat(implemsPrefix, "oracle")),
            debtToken: json.readAddress(string.concat(implemsPrefix, "debtToken")),
            feeAuction: json.readAddress(string.concat(implemsPrefix, "feeAuction")),
            feeReceiver: json.readAddress(string.concat(implemsPrefix, "feeReceiver")),
            chainlinkPoRAddressList: json.readAddress(string.concat(implemsPrefix, "chainlinkPoRAddressList")),
            wrapper: json.readAddress(string.concat(implemsPrefix, "wrapper"))
        });

        string memory libsPrefix = string.concat(chainPrefix, "libs.");
        libs = LibsConfig({
            aaveAdapter: json.readAddress(string.concat(libsPrefix, "aaveAdapter")),
            chainlinkAdapter: json.readAddress(string.concat(libsPrefix, "chainlinkAdapter")),
            capTokenAdapter: json.readAddress(string.concat(libsPrefix, "capTokenAdapter")),
            stakedCapAdapter: json.readAddress(string.concat(libsPrefix, "stakedCapAdapter"))
        });

        string memory infraPrefix = string.concat(chainPrefix, "infra.");
        infra = InfraConfig({
            oracle: json.readAddress(string.concat(infraPrefix, "oracle")),
            accessControl: json.readAddress(string.concat(infraPrefix, "accessControl")),
            lender: json.readAddress(string.concat(infraPrefix, "lender")),
            delegation: json.readAddress(string.concat(infraPrefix, "delegation")),
            chainlinkPoRAddressList: json.readAddress(string.concat(infraPrefix, "chainlinkPoRAddressList")),
            gelatoHarvester: json.readAddress(string.concat(infraPrefix, "gelatoHarvester")),
            gelatoSweeper: json.readAddress(string.concat(infraPrefix, "gelatoSweeper"))
        });
    }
}
