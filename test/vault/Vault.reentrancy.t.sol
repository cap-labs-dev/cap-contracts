// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAccessControl } from "../../contracts/interfaces/IAccessControl.sol";
import { IVault } from "../../contracts/interfaces/IVault.sol";
import { VaultFixture } from "../fixtures/VaultFixture.sol";
import { MockReentrantERC4626 } from "../mocks/MockReentrantERC4626.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

/// @dev Forces a fractional-reserve withdraw while CapToken is mid-call, then tries to reenter
/// each guarded entry point. The shared guard must reject every nested call.
contract VaultReentrancyTest is VaultFixture {
    address user;
    address borrower;
    MockReentrantERC4626 frVault;

    function setUp() public {
        _setUpVaultWithLiquidity();
        user = makeAddr("reentrancy_user");
        borrower = makeAddr("reentrancy_borrower");
        _initTestUserMintCapToken(usdVault, user, 1_000e18);

        frVault = new MockReentrantERC4626(address(usdt), 0, "Reentrant FR", "rFR");

        vm.startPrank(env.users.vault_config_admin);
        cUSD.setReserve(address(usdt), 0);
        cUSD.setFractionalReserveVault(address(usdt), address(frVault));
        cUSD.investAll(address(usdt));
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(cUSD)), 0, "cash must be invested so exits divest");
        assertGt(usdt.balanceOf(address(frVault)), 0, "FR vault should hold the investment");
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    function _expectGuard() internal {
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
    }

    function _burnThatDivests() internal {
        vm.prank(user);
        cUSD.burn(address(usdt), 100e18, 0, user, _deadline());
    }

    function test_reentrancyGuard_blocksMintDuringDivest() public {
        // Leave the FR enough USDT to attempt a nested mint before completing withdraw.
        usdt.mint(address(frVault), 10e6);
        frVault.setAttack(
            address(cUSD), abi.encodeCall(IVault.mint, (address(usdt), 1e6, 0, address(frVault), _deadline()))
        );
        // FR must approve the vault before the nested mint can pull funds.
        vm.prank(address(frVault));
        usdt.approve(address(cUSD), type(uint256).max);

        _expectGuard();
        _burnThatDivests();
    }

    function test_reentrancyGuard_blocksBurnDuringDivest() public {
        vm.prank(user);
        cUSD.transfer(address(frVault), 50e18);
        frVault.setAttack(
            address(cUSD), abi.encodeCall(IVault.burn, (address(usdt), 1e18, 0, address(frVault), _deadline()))
        );

        _expectGuard();
        _burnThatDivests();
    }

    function test_reentrancyGuard_blocksRedeemDuringDivest() public {
        vm.prank(user);
        cUSD.transfer(address(frVault), 50e18);
        uint256[] memory mins = new uint256[](cUSD.assets().length);
        frVault.setAttack(address(cUSD), abi.encodeCall(IVault.redeem, (1e18, mins, address(frVault), _deadline())));

        _expectGuard();
        _burnThatDivests();
    }

    function test_reentrancyGuard_blocksBorrowDuringDivest() public {
        vm.prank(env.users.access_control_admin);
        IAccessControl(env.infra.accessControl).grantAccess(cUSD.borrow.selector, address(cUSD), address(frVault));

        frVault.setAttack(address(cUSD), abi.encodeCall(IVault.borrow, (address(usdt), 1e6, address(frVault))));

        _expectGuard();
        _burnThatDivests();
    }

    function test_reentrancyGuard_blocksRepayDuringDivest() public {
        vm.startPrank(env.users.access_control_admin);
        IAccessControl(env.infra.accessControl).grantAccess(cUSD.borrow.selector, address(cUSD), borrower);
        IAccessControl(env.infra.accessControl).grantAccess(cUSD.repay.selector, address(cUSD), address(frVault));
        vm.stopPrank();

        // Create outstanding borrows so repay has something to reduce, then leave USDT on the FR.
        // Borrow also divests; clear any attack first.
        frVault.clearAttack();
        vm.prank(borrower);
        cUSD.borrow(address(usdt), 10e6, borrower);

        // Re-invest remaining cash so the user's burn still hits the FR withdraw path.
        vm.startPrank(env.users.vault_config_admin);
        cUSD.investAll(address(usdt));
        vm.stopPrank();

        usdt.mint(address(frVault), 1e6);
        vm.prank(address(frVault));
        usdt.approve(address(cUSD), type(uint256).max);
        frVault.setAttack(address(cUSD), abi.encodeCall(IVault.repay, (address(usdt), 1e6)));

        _expectGuard();
        _burnThatDivests();
    }
}
