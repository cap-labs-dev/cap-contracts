// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { L2VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { L2TokenUpgradeable } from "../../contracts/token/L2TokenUpgradeable.sol";
import { CapIntegrationFixture } from "../fixtures/CapIntegrationFixture.sol";

/// @dev Ensures the L2-bridged token proxies are deployed + upgradeable under the vault admin.
contract L2TokenTest is CapIntegrationFixture {
    address user;
    L2TokenUpgradeable l2cap;
    L2TokenUpgradeable l2StakedCap;

    function setUp() public {
        _setUpCap();

        vm.startPrank(env.users.vault_config_admin);
        L2VaultConfig memory l2VaultConfig = _deployL2InfraForVault(env.users, env.usdVault, lzAb);
        vm.stopPrank();

        user = makeAddr("user");
        l2cap = L2TokenUpgradeable(l2VaultConfig.bridgedCapToken);
        l2StakedCap = L2TokenUpgradeable(l2VaultConfig.bridgedStakedCapToken);
    }

    function test_l2token() public view {
        assertEq(l2cap.name(), "Cap USD");
        assertEq(l2StakedCap.name(), "Staked Cap USD");
        assertEq(l2cap.decimals(), 18);
        assertEq(l2StakedCap.decimals(), 18);

        assertEq(l2cap.owner(), env.users.vault_config_admin);
        assertEq(l2StakedCap.owner(), env.users.vault_config_admin);
    }

    function test_l2Token_upgradeTest() public {
        address newImplementation = address(new L2TokenUpgradeable(address(lzAb.endpointV2)));

        vm.startPrank(env.users.vault_config_admin);
        l2cap.upgradeToAndCall(newImplementation, "");
        l2StakedCap.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();

        vm.startPrank(user);
        newImplementation = address(new L2TokenUpgradeable(address(lzAb.endpointV2)));

        vm.expectRevert();
        l2cap.upgradeToAndCall(newImplementation, "");

        vm.expectRevert();
        l2StakedCap.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }
}
