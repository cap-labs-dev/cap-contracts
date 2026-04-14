// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { VaultFixture } from "../fixtures/VaultFixture.sol";

/// @dev Snapshot tests for gas costs of the most common mint/burn paths.
contract VaultGasTest is VaultFixture {
    address user;

    function setUp() public {
        _setUpVault();
        user = makeAddr("test_user");

        usdt.mint(user, 100e6);
        _initTestUserMintCapToken(usdVault, user, 100e18);

        vm.startPrank(user);
        usdt.approve(address(cUSD), 100e6);
        vm.stopPrank();

        assertGt(cUSD.balanceOf(user), 0, "Should have some cUSD to burn");
        assertGt(usdt.balanceOf(user), 0, "Should have some USDT to spend");
    }

    function test_gas_vault_mint() public {
        vm.startPrank(user);

        cUSD.mint(address(usdt), 100e6, 0, user, block.timestamp + 1 hours);
        vm.snapshotGasLastCall("Vault.gas.t", "simple_mint");
    }

    function test_gas_vault_burn() public {
        vm.startPrank(user);

        cUSD.burn(address(usdc), 90e18, 1, user, block.timestamp + 1 hours);
        vm.snapshotGasLastCall("Vault.gas.t", "simple_burn");
    }
}
