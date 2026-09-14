// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Registry } from "../../contracts/cap/Registry.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../../script/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../script/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../script/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../script/deploy/service/DeployInfra.sol";
import { MockCreateX } from "../shared/mocks/MockCreateX.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";

/// @notice The around-existing deploy path keeps the token addresses it is handed.
/// @dev Local CreateX mock, no fork. The live-proxy rehearsal is {UpgradeTest} / {StackTest}.
contract AroundExistingTest is Test, DeployImplems, DeployInfra, ConfigureAccessControl {
    function test_registryIsWiredToTheProxiesItWasHanded() public {
        vm.etch(address(CREATEX), address(new MockCreateX()).code);

        UsersConfig memory users = UsersConfig({
            deployer: address(this),
            governor: makeAddr("governor"),
            keeper: makeAddr("keeper"),
            guardian: makeAddr("guardian"),
            admin: address(this),
            liquidator: makeAddr("liquidator"),
            stablecoinUnderlying: address(new MockERC20("USD Coin", "USDC", 6)),
            reserveVault: address(0)
        });

        address liveCusd = makeAddr("liveCusd");
        address liveStcusd = makeAddr("liveStcusd");

        ImplementationsConfig memory implems = _deployImplementations();
        InfraConfig memory deployed =
            _deployInfraAroundExisting(implems, users, keccak256("around-existing"), liveCusd, liveStcusd);
        _initInfraAccessControl(deployed, users);

        assertEq(deployed.stablecoin, liveCusd);
        assertEq(deployed.wrapper, liveStcusd);
        assertEq(Registry(deployed.registry).stablecoin(), liveCusd);
        assertEq(Registry(deployed.registry).wrapper(), liveStcusd);
        assertTrue(deployed.accessManager != address(0));
        assertTrue(deployed.irm != address(0));
        assertTrue(deployed.vault != address(0));
        assertTrue(deployed.oracle != address(0));
    }
}
