// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract LzUtils {
    struct LzConfig {
        address endpointV2;
        address executor;
        address receiveUln301;
        address receiveUln302;
        address sendUln301;
        address sendUln302;
    }

    function _getLzConfig(Vm vm, uint chainId) public view returns (LzConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/config/layerzero-v2-deployments.json");
        string memory json = vm.readFile(path);

        string memory cmd = string.concat("$..[?(@.nativeChainId == ", vm.toString(chainId), ")]");
        bytes memory rawData = vm.parseJson(json, cmd);

        bytes memory data = new bytes(rawData.length - 64);
        for (uint i = 0; i < data.length; i++) {
            data[i] = rawData[i + 64];
        }
        config = abi.decode(data, (LzConfig));

        console.log("LzUtils: chainId", chainId);
        console.log("LzUtils: endpointV2", config.endpointV2);
    }
}
