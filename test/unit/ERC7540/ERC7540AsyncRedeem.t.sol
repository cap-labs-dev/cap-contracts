// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC7540AsyncRedeem } from "../../../contracts/ERC7540/ERC7540AsyncRedeem.sol";
import { IERC7540AsyncRedeem } from "../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Minimal concrete async-redeem vault whose available liquidity (unlockedSupply) is settable,
/// so the FIFO redemption queue can be exercised deterministically.
contract MockAsyncVault is ERC7540AsyncRedeem {
    uint256 private _unlocked;

    function initialize(IERC20 asset_) external initializer {
        __ERC7540AsyncRedeem_init(asset_, "Mock Vault", "mVLT", "");
    }

    function unlockedSupply() public view override returns (uint256) {
        return _unlocked;
    }

    function setUnlocked(uint256 u) external {
        _unlocked = u;
    }
}

contract ERC7540AsyncRedeemTest is Test {
    MockAsyncVault internal vault;
    MockERC20 internal asset;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        asset = new MockERC20("Token", "TKN", 18);
        vault = new MockAsyncVault();
        vault.initialize(IERC20(address(asset)));

        asset.mint(alice, 1_000e18);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18, alice); // 1:1 -> 1000 shares, vault holds 1000 asset
        vm.stopPrank();
    }

    // --- request mechanics ---

    function test_requestRedeem_escrowsSharesAndMintsReceipt() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);

        assertEq(id, 0);
        assertEq(vault.balanceOf(alice), 600e18); // shares moved into escrow
        assertEq(vault.balanceOf(address(vault)), 400e18);
        assertEq(vault.redemptionQueue(), 400e18);
        assertEq(vault.activeSupply(), 600e18);
    }

    function test_requestRedeem_zeroShares_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_requestRedeem_insufficientBalance_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(2_000e18, alice, alice);
    }

    // --- claimable / pending across the FIFO boundary ---

    function test_fullyClaimable_whenLiquidityCoversRequest() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);
        assertEq(vault.claimableRedeemRequest(id, alice), 400e18);
        assertEq(vault.pendingRedeemRequest(id, alice), 0);
    }

    function test_partiallyClaimable_whenLiquidityLimited() public {
        vault.setUnlocked(300e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000e18, alice, alice);

        assertEq(vault.claimableRedeemRequest(id, alice), 300e18);
        assertEq(vault.pendingRedeemRequest(id, alice), 700e18);
    }

    function test_claimableGrows_asLiquidityReturns() public {
        vault.setUnlocked(300e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000e18, alice, alice);

        vm.prank(alice);
        vault.redeem(id, 300e18, alice, alice); // drain currently claimable

        // more liquidity becomes available
        vault.setUnlocked(1_000e18);
        assertEq(vault.claimableRedeemRequest(id, alice), 700e18);
    }

    function test_fifo_firstRequestSettlesBeforeSecond() public {
        vault.setUnlocked(500e18);
        vm.startPrank(alice);
        uint256 id0 = vault.requestRedeem(400e18, alice, alice);
        uint256 id1 = vault.requestRedeem(400e18, alice, alice);
        vm.stopPrank();

        // 500 of liquidity: first request (400) fully claimable, second gets the remaining 100
        assertEq(vault.claimableRedeemRequest(id0, alice), 400e18);
        assertEq(vault.claimableRedeemRequest(id1, alice), 100e18);
    }

    // --- redeem / withdraw execution ---

    function test_redeem_transfersAssetsAndBurnsShares() public {
        vault.setUnlocked(1_000e18);
        vm.startPrank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);
        uint256 assets = vault.redeem(id, 400e18, alice, alice);
        vm.stopPrank();

        assertEq(assets, 400e18);
        assertEq(asset.balanceOf(alice), 400e18);
        assertEq(vault.totalSupply(), 600e18); // escrowed shares burned
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.claimableRedeemRequest(id, alice), 0);
    }

    function test_redeem_exceedingClaimable_reverts() public {
        vault.setUnlocked(300e18);
        vm.startPrank(alice);
        uint256 id = vault.requestRedeem(1_000e18, alice, alice);
        vm.expectRevert();
        vault.redeem(id, 301e18, alice, alice);
        vm.stopPrank();
    }

    function test_withdraw_byAssets() public {
        vault.setUnlocked(1_000e18);
        vm.startPrank(alice);
        uint256 id = vault.requestRedeem(250e18, alice, alice);
        uint256 shares = vault.withdraw(id, 250e18, alice, alice);
        vm.stopPrank();

        assertEq(shares, 250e18);
        assertEq(asset.balanceOf(alice), 250e18);
    }

    // --- instant redeem accounting ---

    function test_maxRedeem_capByInstantUnlocked() public {
        vault.setUnlocked(700e18);
        assertEq(vault.maxRedeem(alice), 700e18); // min(balance 1000, unlocked 700)

        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);
        // instantUnlocked = unlocked - redemptionQueue = 700 - 200 = 500; balance now 800
        assertEq(vault.maxRedeem(alice), 500e18);
    }

    // --- operator / allowance ---

    function test_operatorCanRequestAndRedeemOnBehalf() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        uint256 id = vault.requestRedeem(300e18, alice, alice);

        vm.prank(bob);
        uint256 assets = vault.redeem(id, 300e18, alice, alice);
        assertEq(assets, 300e18);
        assertEq(asset.balanceOf(alice), 300e18);
    }

    function test_nonOperatorWithoutAllowance_reverts() public {
        vault.setUnlocked(1_000e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.requestRedeem(300e18, bob, alice);
    }

    function test_allowanceAllowsThirdPartyRequest() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        vault.approve(bob, 300e18);

        vm.prank(bob);
        uint256 id = vault.requestRedeem(300e18, bob, alice);
        // receipt controlled by bob
        assertEq(vault.claimableRedeemRequest(id, bob), 300e18);
    }
}
