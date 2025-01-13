// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILayerZeroEndpointV2 } from "@layerzerolabs/interfaces/ILayerZeroEndpointV2.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract LzUtils {
    struct LzConfig {
        uint32 eid;
        ILayerZeroEndpointV2 endpointV2;
        address executor;
        uint32 nativeChainId;
        address receiveUln301;
        address receiveUln302;
        address sendUln301;
        address sendUln302;
    }

    function fieldKey(Vm vm, uint chainId, string memory _field) public pure returns (string memory key) {
        key = string.concat("$['", vm.toString(chainId), "'].", _field);
    }

    function getLzConfig(Vm vm, uint chainId) public view returns (LzConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/config/layerzero-v2-deployments.json");
        string memory json = vm.readFile(path);

        config.eid = uint32(vm.parseJsonUint(json, fieldKey(vm, chainId, "eid")));
        config.endpointV2 = ILayerZeroEndpointV2(vm.parseJsonAddress(json, fieldKey(vm, chainId, "endpointV2")));
        config.executor = vm.parseJsonAddress(json, fieldKey(vm, chainId, "executor"));
        config.nativeChainId = uint32(vm.parseJsonUint(json, fieldKey(vm, chainId, "nativeChainId")));
        config.receiveUln301 = vm.parseJsonAddress(json, fieldKey(vm, chainId, "receiveUln301"));
        config.receiveUln302 = vm.parseJsonAddress(json, fieldKey(vm, chainId, "receiveUln302"));
        config.sendUln301 = vm.parseJsonAddress(json, fieldKey(vm, chainId, "sendUln301"));
        config.sendUln302 = vm.parseJsonAddress(json, fieldKey(vm, chainId, "sendUln302"));
    }
}
