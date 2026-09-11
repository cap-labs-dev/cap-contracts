// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { BaseTest } from "../../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../../test/shared/mocks/MockIRM.sol";
import { LossyAeraVault } from "../../N2/LossyAeraVault.sol";

/// Is the blocked claim a delay (recoverable by recall) or a loss? Does the queue state survive a reverted claim?
contract VerifyInvestLiquidity is BaseTest {
    Stablecoin sc;
    MockERC20 asset;
    MockIRM irm;
    LossyAeraVault aera;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USDC", "USDC", 18);
        irm = new MockIRM();
        aera = new LossyAeraVault();
        Stablecoin impl = new Stablecoin();
        sc = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(asset), "cUSD", "cUSD", "", address(irm), address(aera))
                )
            )
        );
        asset.mint(alice, 1_000e18);
        asset.mint(bob, 1_000e18);
        vm.prank(alice);
        asset.approve(address(sc), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(sc), type(uint256).max);
    }

    function test_queuedClaimIsDelayedNotLost() public {
        vm.prank(alice);
        sc.deposit(1_000e18, alice);
        vm.prank(alice);
        uint256 id = sc.requestRedeem(1_000e18, alice, alice);
        sc.invest(1e18);
        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(id, 1_000e18, alice, alice);
        // state untouched by the revert
        assertEq(sc.claimableRedeemRequest(id, alice), 1_000e18);
        assertEq(sc.redemptionQueue(), 1_000e18);
        // keeper recalls -> claim settles in full, alice whole
        sc.recall(1e18);
        vm.prank(alice);
        uint256 out = sc.redeem(id, 1_000e18, alice, alice);
        assertEq(out, 1_000e18);
        assertEq(asset.balanceOf(alice), 1_000e18);
        assertEq(sc.redemptionQueue(), 0);
        assertEq(sc.totalSupply(), 0);
    }

    function test_partialClaimThenRecallThenRemainder() public {
        vm.prank(alice);
        sc.deposit(1_000e18, alice);
        vm.prank(alice);
        uint256 id = sc.requestRedeem(1_000e18, alice, alice);
        sc.invest(300e18);
        vm.prank(alice);
        sc.redeem(id, 700e18, alice, alice);
        assertEq(sc.claimableRedeemRequest(id, alice), 300e18);
        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(id, 300e18, alice, alice);
        sc.recall(300e18);
        vm.prank(alice);
        sc.redeem(id, 300e18, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000e18);
    }

    /// New depositor liquidity also unblocks the claim without any keeper action (a liquid reserve is fungible)
    function test_newDepositUnblocksWithoutRecall() public {
        vm.prank(alice);
        sc.deposit(1_000e18, alice);
        vm.prank(alice);
        uint256 id = sc.requestRedeem(1_000e18, alice, alice);
        sc.invest(500e18);
        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(id, 1_000e18, alice, alice);
        vm.prank(bob);
        sc.deposit(500e18, bob);
        vm.prank(alice);
        sc.redeem(id, 1_000e18, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000e18);
        // bob is now the one who cannot instantly exit despite maxRedeem saying so
        assertEq(sc.maxRedeem(bob), 500e18);
        assertEq(asset.balanceOf(address(sc)), 0);
        vm.prank(bob);
        vm.expectRevert();
        sc.redeem(500e18, bob, bob);
    }
}
