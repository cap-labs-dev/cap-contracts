// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

struct EigenAddresses {
    address allocationManager;
    address delegationManager;
    address strategyManager;
    address rewardsCoordinator;
    address permissionsController;
    address strategyFactory;
    address strategy;
}

struct EigenAddressbook {
    EigenAddresses eigenAddresses;
}

struct VaultAddressbook {
    address strategy;
    address curator;
}

contract EigenUtils {
    using stdJson for string;

    string public constant EIGEN_CONFIG_PATH_FROM_PROJECT_ROOT = "config/eigen.json";

    function _getEigenAddressbook() internal view returns (EigenAddressbook memory ab) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        string memory configJson = vm.readFile(EIGEN_CONFIG_PATH_FROM_PROJECT_ROOT);
        string memory selectorPrefix = string.concat("$['", vm.toString(block.chainid), "']");

        console.log("block.chainid", block.chainid);

        // mainnet
        ab.eigenAddresses.allocationManager =
            configJson.readAddress(string.concat(selectorPrefix, ".allocationManager"));
        ab.eigenAddresses.delegationManager =
            configJson.readAddress(string.concat(selectorPrefix, ".delegationManager"));
        ab.eigenAddresses.strategyManager = configJson.readAddress(string.concat(selectorPrefix, ".strategyManager"));
        ab.eigenAddresses.rewardsCoordinator =
            configJson.readAddress(string.concat(selectorPrefix, ".rewardsCoordinator"));
        ab.eigenAddresses.permissionsController =
            configJson.readAddress(string.concat(selectorPrefix, ".permissionsController"));
        ab.eigenAddresses.strategyFactory = configJson.readAddress(string.concat(selectorPrefix, ".strategyFactory"));
        ab.eigenAddresses.strategy = configJson.readAddress(string.concat(selectorPrefix, ".strategy"));
    }

    function _getEigenVaultAddressbook(address asset) internal view returns (VaultAddressbook memory ab) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        string memory configJson = vm.readFile(EIGEN_CONFIG_PATH_FROM_PROJECT_ROOT);
        string memory selectorPrefix =
            string.concat("$['", vm.toString(block.chainid), "'].vaults[", vm.toString(asset), "]");

        ab.strategy = configJson.readAddress(string.concat(selectorPrefix, ".strategy"));
        ab.curator = configJson.readAddress(string.concat(selectorPrefix, ".curator"));
    }
}
