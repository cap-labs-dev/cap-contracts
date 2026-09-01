// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vault } from "../../../contracts/cap/Vault.sol";
import { AssetId } from "../../../contracts/utils/AssetId.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract VaultTest is BaseTest {
    Vault internal vault;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpAccessManager();
        token = new MockERC20("Token", "TKN", 18);

        Vault impl = new Vault();
        vault = Vault(_deployProxy(address(impl), abi.encodeCall(Vault.initialize, (address(accessManager)))));

        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        vault.initialize(address(accessManager));
    }

    function test_id_and_asset_roundtrip() public view {
        uint256 expected = AssetId.toId(address(token));
        assertEq(vault.id(address(token)), expected);
        assertEq(vault.asset(expected), address(token));
    }

    function test_deposit_mintsBalanceAndPullsTokens() public {
        vm.prank(alice);
        vault.deposit(address(token), 100e18, alice);

        assertEq(vault.balanceOf(alice, address(token)), 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(token.balanceOf(alice), 900e18);
        assertEq(vault.totalSupply(AssetId.toId(address(token))), 100e18);
    }

    function test_deposit_toOtherRecipient() public {
        vm.prank(alice);
        vault.deposit(address(token), 50e18, bob);
        assertEq(vault.balanceOf(bob, address(token)), 50e18);
        assertEq(vault.balanceOf(alice, address(token)), 0);
    }

    function test_withdraw_burnsAndReturnsTokens() public {
        vm.prank(alice);
        vault.deposit(address(token), 100e18, alice);

        vm.prank(alice);
        vault.withdraw(address(token), 40e18, alice);

        assertEq(vault.balanceOf(alice, address(token)), 60e18);
        assertEq(token.balanceOf(alice), 940e18);
        assertEq(token.balanceOf(address(vault)), 60e18);
    }

    function test_withdraw_moreThanBalance_reverts() public {
        vm.prank(alice);
        vault.deposit(address(token), 10e18, alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(address(token), 20e18, alice);
    }

    function test_transfer_movesBalance() public {
        vm.prank(alice);
        vault.deposit(address(token), 100e18, alice);

        vm.prank(alice);
        vault.transfer(bob, address(token), 30e18);

        assertEq(vault.balanceOf(alice, address(token)), 70e18);
        assertEq(vault.balanceOf(bob, address(token)), 30e18);
    }

    function test_transferFrom_requiresApprovalOrOperator() public {
        vm.prank(alice);
        vault.deposit(address(token), 100e18, alice);

        // bob without approval cannot move alice's balance
        vm.prank(bob);
        vm.expectRevert();
        vault.transferFrom(alice, bob, address(token), 10e18);

        // approve bob as operator
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        vault.transferFrom(alice, bob, address(token), 10e18);
        assertEq(vault.balanceOf(bob, address(token)), 10e18);
    }

    function test_upgrade_authorized() public {
        Vault newImpl = new Vault();
        UUPSUpgradeable(address(vault)).upgradeToAndCall(address(newImpl), "");
        assertEq(vault.id(address(token)), AssetId.toId(address(token))); // still functional
    }

    function test_upgrade_unauthorized_reverts() public {
        Vault newImpl = new Vault();
        vm.prank(bob);
        vm.expectRevert();
        UUPSUpgradeable(address(vault)).upgradeToAndCall(address(newImpl), "");
    }

    function testFuzz_depositWithdraw(uint256 amount) public {
        amount = bound(amount, 1, 1_000e18);
        vm.prank(alice);
        vault.deposit(address(token), amount, alice);
        assertEq(vault.balanceOf(alice, address(token)), amount);

        vm.prank(alice);
        vault.withdraw(address(token), amount, alice);
        assertEq(vault.balanceOf(alice, address(token)), 0);
        assertEq(token.balanceOf(alice), 1_000e18);
    }
}
