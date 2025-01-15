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

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @dev Constructs a key for accessing a field in a JSON object.
     * @param vm The Vm instance.
     * @param chainId The chain ID.
     * @param _field The field name.
     * @return key The constructed key.
     */
    function _fieldKey(Vm vm, uint chainId, string memory _field) private pure returns (string memory key) {
        key = string.concat("$['", vm.toString(chainId), "'].", _field);
    }

    /**
     * @dev Retrieves the LayerZero configuration for a given chain ID.
     * @param vm The Vm instance.
     * @param chainId The chain ID.
     * @return config The LayerZero configuration.
     */
    function getLzConfig(Vm vm, uint chainId) public view returns (LzConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/config/layerzero-v2-deployments.json");
        string memory json = vm.readFile(path);

        config.eid = uint32(vm.parseJsonUint(json, _fieldKey(vm, chainId, "eid")));
        config.endpointV2 = ILayerZeroEndpointV2(vm.parseJsonAddress(json, _fieldKey(vm, chainId, "endpointV2")));
        config.executor = vm.parseJsonAddress(json, _fieldKey(vm, chainId, "executor"));
        config.nativeChainId = uint32(vm.parseJsonUint(json, _fieldKey(vm, chainId, "nativeChainId")));
        config.receiveUln301 = vm.parseJsonAddress(json, _fieldKey(vm, chainId, "receiveUln301"));
        config.receiveUln302 = vm.parseJsonAddress(json, _fieldKey(vm, chainId, "receiveUln302"));
        config.sendUln301 = vm.parseJsonAddress(json, _fieldKey(vm, chainId, "sendUln301"));
        config.sendUln302 = vm.parseJsonAddress(json, _fieldKey(vm, chainId, "sendUln302"));
    }
}
