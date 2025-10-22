// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { EigenConfig, EigenImplementationsConfig } from "../../contracts/deploy/interfaces/EigenDeployConfig.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract EigenAdapterConfigSerializer {
    using stdJson for string;

    function _eigenConfigFilePath() private view returns (string memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        return string.concat(vm.projectRoot(), "/config/cap-eigen.json");
    }

    function _saveEigenConfig(EigenImplementationsConfig memory implems, EigenConfig memory adapter) internal {
        string memory implemsJson = "implems";
        implemsJson.serialize("eigenServiceManager", implems.eigenServiceManager);
        implemsJson.serialize("operator", implems.operator);
        implemsJson = implemsJson.serialize("agentManager", implems.agentManager);
        console.log(implemsJson);

        string memory adapterJson = "adapter";
        adapterJson.serialize("eigenServiceManager", adapter.eigenServiceManager);
        adapterJson = adapterJson.serialize("agentManager", adapter.agentManager);
        console.log(adapterJson);

        string memory chainJson = "chain";
        chainJson.serialize("implems", implemsJson);
        chainJson = chainJson.serialize("adapter", adapterJson);
        console.log(chainJson);

        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory previousJson = vm.readFile(_eigenConfigFilePath());
        string memory mergedJson = "merged";
        mergedJson.serialize(previousJson);
        mergedJson = mergedJson.serialize(Strings.toString(block.chainid), chainJson);
        vm.writeFile(_eigenConfigFilePath(), mergedJson);
    }

    function _readEigenConfig()
        internal
        view
        returns (EigenImplementationsConfig memory implems, EigenConfig memory adapter)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        string memory json = vm.readFile(_eigenConfigFilePath());
        string memory chainPrefix = string.concat("$['", Strings.toString(block.chainid), "'].");

        string memory implemsPrefix = string.concat(chainPrefix, "implems.");
        implems = EigenImplementationsConfig({
            eigenServiceManager: json.readAddress(string.concat(implemsPrefix, "eigenServiceManager")),
            operator: json.readAddress(string.concat(implemsPrefix, "operator")),
            agentManager: json.readAddress(string.concat(implemsPrefix, "agentManager"))
        });

        string memory adapterPrefix = string.concat(chainPrefix, "adapter.");
        adapter = EigenConfig({
            eigenServiceManager: json.readAddress(string.concat(adapterPrefix, "eigenServiceManager")),
            agentManager: json.readAddress(string.concat(adapterPrefix, "agentManager")),
            rewardDuration: json.readUint(string.concat(adapterPrefix, "rewardDuration"))
        });
    }
}
