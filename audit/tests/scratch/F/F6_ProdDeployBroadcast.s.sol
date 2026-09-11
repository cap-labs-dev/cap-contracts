// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console } from "forge-std/Script.sol";

import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "../../../../contracts/deploy/service/DeployLibs.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { MockOracle } from "../../../../test/shared/mocks/MockOracle.sol";

/// WS-F. The same shape as script/DeployInfra.s.sol (which itself does not compile), with the
/// UsersConfig fixed up, run under vm.startBroadcast() the way the real script is. Checks whether
/// DeployInfra's `VM.getNonce(address(this))` / `computeCreateAddress(address(this), n)` survives
/// broadcast, where CREATEs are attributed to the broadcaster rather than the script contract.
///
///   forge script audit/tests/scratch/F/F6_ProdDeployBroadcast.s.sol --sender 0x1000...0001 -vvv
contract F6_ProdDeployBroadcast is Script, DeployImplems, DeployInfra, DeployLibs, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;

    function run() external {
        address wallet = msg.sender;
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockOracle oracle = new MockOracle();

        vm.startBroadcast();
        users = UsersConfig({
            deployer: wallet,
            governor: wallet,
            keeper: wallet,
            guardian: wallet,
            admin: wallet,
            liquidator: wallet,
            stablecoinUnderlying: address(usdc),
            stakedStablecoin: wallet,
            oracle: address(oracle)
        });
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
        vm.stopBroadcast();

        console.log("deployed registry at", infra.registry);
    }
}
