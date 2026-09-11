// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../../../contracts/deploy/service/DeployInfra.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";
import { Script, console } from "forge-std/Script.sol";

/// Port of round-1 F6_ProdDeployBroadcast (L-8): production deploy path under vm.startBroadcast
contract R2_L8_ProdDeployBroadcast is Script, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;

    function run() external {
        address wallet = msg.sender;
        vm.startBroadcast();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        users = UsersConfig({
            deployer: wallet,
            governor: wallet,
            keeper: wallet,
            guardian: wallet,
            admin: wallet,
            liquidator: wallet,
            stablecoinUnderlying: address(usdc),
            reserveVault: address(0)
        });
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
        vm.stopBroadcast();
        console.log("registry", infra.registry);
        console.log("oracle", infra.oracle);
        console.log("chainlinkAdapter", infra.chainlinkAdapter);
    }
}
