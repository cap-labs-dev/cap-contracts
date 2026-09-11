// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../../contracts/deploy/service/DeployInfra.sol";
import { MockAeraVault } from "../../../../../test/shared/mocks/MockAeraVault.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Script, console } from "forge-std/Script.sol";

/// L-8 residual (port of round-1 F6): DeployInfra under vm.startBroadcast(), where CREATEs and
/// calls are attributed to the broadcaster, not the script contract.
///   FOUNDRY_TEST=audit/v2/tests/scratch/N3 forge script audit/v2/tests/scratch/N3/N3_ProdDeployBroadcast.s.sol --sender 0x1000000000000000000000000000000000000001 -vvv
contract N3_ProdDeployBroadcast is Script, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;

    function run() external {
        address wallet = msg.sender;
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAeraVault aera = new MockAeraVault();
        vm.startBroadcast();
        users = UsersConfig({
            deployer: wallet,
            governor: wallet,
            keeper: wallet,
            guardian: wallet,
            admin: wallet,
            liquidator: wallet,
            stablecoinUnderlying: address(usdc),
            reserveVault: address(aera)
        });
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
        vm.stopBroadcast();
        console.log("deployed registry at", infra.registry);
    }
}
