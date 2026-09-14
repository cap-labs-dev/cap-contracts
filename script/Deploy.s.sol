// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InfraSerializer } from "./config/InfraSerializer.sol";
import { Users } from "./config/Users.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "./deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "./deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "./deploy/service/DeployImplems.sol";
import { DeployInfra } from "./deploy/service/DeployInfra.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @title Deploy
/// @notice Deploy Cap infrastructure through CreateX and write `config/cap-v2.json`
/// @dev The broadcast account must hold `previewMint(1e18)` of `STABLECOIN_UNDERLYING` for the wrapper seed.
contract Deploy is Script, Users, InfraSerializer, DeployImplems, DeployInfra, ConfigureAccessControl {
    function run() external {
        UsersConfig memory users = _users();

        vm.startBroadcast();
        ImplementationsConfig memory implems = _deployImplementations();
        InfraConfig memory infra = _deployInfra(implems, users, vm.envOr("SALT_NAMESPACE", bytes32(0)));
        _initInfraAccessControl(infra, users);
        vm.stopBroadcast();

        _saveInfra(implems, infra);

        console.log("accessManager", infra.accessManager);
        console.log("registry     ", infra.registry);
        console.log("stablecoin   ", infra.stablecoin);
        console.log("wrapper      ", infra.wrapper);
        console.log("oracle       ", infra.oracle);
        console.log("irm          ", infra.irm);
    }
}
