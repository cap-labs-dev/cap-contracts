// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC7540AsyncRedeem } from "../../../../contracts/ERC7540/ERC7540AsyncRedeem.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Same settable-liquidity harness as test/unit/ERC7540/ERC7540AsyncRedeem.t.sol
contract FifoVault is ERC7540AsyncRedeem {
    uint256 private _unlocked;

    function initialize(IERC20 asset_) external initializer {
        __ERC7540AsyncRedeem_init(asset_, "Fifo Vault", "fVLT");
    }

    function unlockedSupply() public view override returns (uint256) {
        return _unlocked;
    }

    function setUnlocked(uint256 u) external {
        _unlocked = u;
    }
}

/// @notice Kills the FIFO-watermark survivors in {ERC7540AsyncRedeem}:
/// - `#50`: the `_shares > claimableRedeemRequest` check in the 4-arg {redeem} dropped. The inner
///   `_claim` still bounds a claim by *total* unlocked supply, so every existing over-claim test
///   still reverts with the same error — but a later request could take liquidity the watermark
///   had allocated to an earlier one (I15).
/// - `#176`: `currentIndex <= queueIndex` → false, so a request wholly behind the watermark makes
///   `claimableRedeemRequest` underflow and `maxRedeem`/`redeem(3-arg)` revert for that controller.
/// - `#288`: `_consumeRequest` advances `queueIndex` by 1 instead of by the shares consumed, so a
///   partially settled request re-reports liquidity that belongs to the request ahead of it (I17).
/// - `#260`/`#274`: the insertion sort in `_sortIds` compares against `ids[0]` / drops the key, so
///   three or more ids that EnumerableSet's swap-remove has left out of order are claimed out of FIFO.
contract RedeemFifoKillTest is Test {
    FifoVault internal vault;
    MockERC20 internal asset;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        asset = new MockERC20("Token", "TKN", 18);
        vault = new FifoVault();
        vault.initialize(IERC20(address(asset)));
        asset.mint(alice, 1_000e18);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18, alice);
        vm.stopPrank();
    }

    function test_aLaterRequestCannotClaimLiquidityAllocatedToAnEarlierOne() public {
        vault.setUnlocked(500e18);
        vm.prank(alice);
        uint256 first = vault.requestRedeem(400e18, alice, alice);
        vm.prank(alice);
        uint256 second = vault.requestRedeem(400e18, bob, alice);

        assertEq(vault.claimableRedeemRequest(first, alice), 400e18, "the first request is fully claimable");
        assertEq(vault.claimableRedeemRequest(second, bob), 100e18, "the second only gets what is left");

        // bob asks for his whole request: within unlocked, but 300 of it belongs to alice's place in the queue
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, bob, 400e18, 100e18)
        );
        vault.redeem(second, 400e18, bob, bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, bob, 101e18, 100e18)
        );
        vault.withdraw(second, 101e18, bob, bob);

        // and the first request can still take everything it was promised
        vm.prank(alice);
        assertEq(vault.redeem(first, 400e18, alice, alice), 400e18);
        // the watermark has moved past alice, so with the same liquidity bob's whole request is now reachable
        assertEq(vault.claimableRedeemRequest(second, bob), 400e18, "and only then does bob's turn come");
    }

    /// Kills #176: a request wholly behind the watermark is pending, not a revert.
    function test_aRequestWhollyBehindTheWatermarkIsPendingNotARevert() public {
        vault.setUnlocked(300e18);
        vm.startPrank(alice);
        uint256 first = vault.requestRedeem(400e18, alice, alice);
        uint256 second = vault.requestRedeem(400e18, alice, alice);
        vm.stopPrank();

        assertEq(vault.claimableRedeemRequest(first, alice), 300e18);
        assertEq(vault.claimableRedeemRequest(second, alice), 0, "nothing reaches the second yet");
        assertEq(vault.pendingRedeemRequest(second, alice), 400e18);
        assertEq(vault.maxRedeem(alice), 300e18, "the view must not revert");

        vm.prank(alice);
        assertEq(vault.redeem(300e18, alice, alice), 300e18, "nor the FIFO claim");
    }

    /// Kills #288: after a partial settlement of the request behind it, an earlier request keeps
    /// its whole slice of new liquidity.
    function test_aPartiallySettledRequestDoesNotReReportLiquidityAheadOfIt() public {
        vault.setUnlocked(700e18);
        vm.startPrank(alice);
        uint256 first = vault.requestRedeem(500e18, alice, alice);
        uint256 second = vault.requestRedeem(500e18, alice, alice);
        assertEq(vault.claimableRedeemRequest(second, alice), 200e18);
        vault.redeem(second, 200e18, alice, alice);
        vm.stopPrank();

        vault.setUnlocked(600e18);
        assertEq(vault.claimableRedeemRequest(first, alice), 500e18, "the first request is whole");
        assertEq(vault.claimableRedeemRequest(second, alice), 100e18, "the second only gets what is left past it");
        assertLe(
            vault.claimableRedeemRequest(first, alice) + vault.claimableRedeemRequest(second, alice),
            vault.unlockedSupply(),
            "claimable never sums past unlocked (I17)"
        );
    }

    /// Kills #260 / #274: ids left out of order by a swap-remove are still claimed oldest first.
    function test_fifoClaimSortsIdsLeftOutOfOrderByARemoval() public {
        vault.setUnlocked(1_000e18);
        vm.startPrank(alice);
        uint256 r1 = vault.requestRedeem(100e18, alice, alice);
        uint256 r2 = vault.requestRedeem(100e18, alice, alice);
        uint256 r3 = vault.requestRedeem(100e18, alice, alice);
        uint256 r4 = vault.requestRedeem(100e18, alice, alice);
        // settling the first in full swap-removes it: the set now reads {r4, r2, r3}
        vault.redeem(r1, 100e18, alice, alice);

        // a FIFO claim of 250 must take all of r2 and r3 and half of r4, in that order
        vault.redeem(250e18, alice, alice);
        vm.stopPrank();

        assertEq(vault.claimableRedeemRequest(r2, alice) + vault.pendingRedeemRequest(r2, alice), 0, "r2 consumed");
        assertEq(vault.claimableRedeemRequest(r3, alice) + vault.pendingRedeemRequest(r3, alice), 0, "r3 consumed");
        assertEq(vault.claimableRedeemRequest(r4, alice) + vault.pendingRedeemRequest(r4, alice), 50e18, "r4 half");
    }

    /// Kills #120: `maxInstantWithdraw` is the asset value of `maxInstantRedeem`.
    function test_maxInstantWithdrawIsTheValueOfMaxInstantRedeem() public {
        vault.setUnlocked(700e18);
        assertEq(vault.maxInstantRedeem(alice), 700e18);
        assertEq(vault.maxInstantWithdraw(alice), 700e18, "at par, the same figure in assets");
    }
}
