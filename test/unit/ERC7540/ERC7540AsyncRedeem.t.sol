// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC7540AsyncRedeem } from "../../../contracts/ERC7540/ERC7540AsyncRedeem.sol";
import { IERC7540AsyncRedeem } from "../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IERC7540Operator } from "../../../contracts/interfaces/IERC7540Operator.sol";
import { IERC7540Redeem } from "../../../contracts/interfaces/IERC7540Redeem.sol";
import { IERC7575 } from "../../../contracts/interfaces/IERC7575.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Minimal concrete async-redeem vault whose available liquidity (unlockedSupply) is settable,
/// so the FIFO redemption queue can be exercised deterministically.
contract MockAsyncVault is ERC7540AsyncRedeem {
    uint256 private _unlocked;

    function initialize(IERC20 asset_) external initializer {
        __ERC7540AsyncRedeem_init(asset_, "Mock Vault", "mVLT");
    }

    function unlockedSupply() public view override returns (uint256) {
        return _unlocked;
    }

    function setUnlocked(uint256 u) external {
        _unlocked = u;
    }
}

/// @dev A vault that does NOT override unlockedSupply, exercising the base (zero) implementation.
contract MockBareVault is ERC7540AsyncRedeem {
    function initialize(IERC20 asset_) external initializer {
        __ERC7540AsyncRedeem_init(asset_, "Bare Vault", "bVLT");
    }
}

contract ERC7540AsyncRedeemTest is Test {
    MockAsyncVault internal vault;
    MockERC20 internal asset;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

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

    function test_requestRedeem_escrowsShares() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);

        assertEq(id, 1, "nonzero ids must never start at 0");
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

    /// @dev A zero controller cannot later transfer or claim. Reject before the escrow so shares
    /// stay with the owner. Abandoned requests under a real controller are a separate policy.
    function test_requestRedeem_zeroController_reverts() public {
        uint256 ownerShares = vault.balanceOf(alice);
        uint256 escrowed = vault.balanceOf(address(vault));
        uint256 queued = vault.redemptionQueue();

        vm.prank(alice);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroAddress.selector);
        vault.requestRedeem(400e18, address(0), alice);

        assertEq(vault.balanceOf(alice), ownerShares);
        assertEq(vault.balanceOf(address(vault)), escrowed);
        assertEq(vault.redemptionQueue(), queued);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);
        assertEq(id, 1, "failed zero-controller request must not consume a request id");
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

    /// @dev A later 4-arg claim advances `settledQueue` without filling the prefix. The earlier
    /// request must recap to current unlocked, not stay claimable against a stale watermark.
    function test_laterClaimDoesNotKeepEarlierRequestClaimableAfterLiquidityFalls() public {
        vault.setUnlocked(200e18);
        vm.startPrank(alice);
        uint256 id0 = vault.requestRedeem(100e18, alice, alice);
        uint256 id1 = vault.requestRedeem(100e18, alice, alice);
        vault.redeem(id1, 100e18, alice, alice);
        vm.stopPrank();

        vault.setUnlocked(0);
        assertEq(vault.unlockedSupply(), 0);
        assertEq(vault.claimableRedeemRequest(id0, alice), 0, "earlier request is not claimable without liquidity");
        assertEq(vault.pendingRedeemRequest(id0, alice), 100e18, "the shares stay pending");
        assertEq(vault.maxRedeem(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, alice, 100e18, 0));
        vault.redeem(id0, 100e18, alice, alice);
    }

    function test_laterClaimRecapsEarlierRequestToRemainingUnlocked() public {
        vault.setUnlocked(200e18);
        vm.startPrank(alice);
        uint256 id0 = vault.requestRedeem(100e18, alice, alice);
        uint256 id1 = vault.requestRedeem(100e18, alice, alice);
        vault.redeem(id1, 100e18, alice, alice);
        vm.stopPrank();

        vault.setUnlocked(40e18);
        assertEq(vault.claimableRedeemRequest(id0, alice), 40e18);
        assertEq(vault.pendingRedeemRequest(id0, alice), 60e18);
        assertEq(vault.maxRedeem(alice), 40e18);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(id0, 41e18, alice, alice);

        vm.prank(alice);
        assertEq(vault.redeem(id0, 40e18, alice, alice), 40e18);
    }

    function test_outOfOrderClaimStillAllowedWhileLiquid() public {
        vault.setUnlocked(200e18);
        vm.startPrank(alice);
        uint256 id0 = vault.requestRedeem(100e18, alice, alice);
        uint256 id1 = vault.requestRedeem(100e18, alice, alice);
        assertEq(vault.redeem(id1, 100e18, alice, alice), 100e18, "later request may settle first");
        assertEq(vault.redeem(id0, 100e18, alice, alice), 100e18, "earlier request still settles after");
        vm.stopPrank();
    }

    /// @dev After a later request settles, two earlier leftovers can each look claimable up to
    /// unlocked. Aggregate maxRedeem and FIFO must share that budget.
    function test_fifoAndMaxRedeemShareTheUnlockedBudget() public {
        vault.setUnlocked(200e18);
        vm.startPrank(alice);
        vault.requestRedeem(50e18, alice, alice);
        vault.requestRedeem(50e18, alice, alice);
        vault.requestRedeem(50e18, alice, alice);
        vault.redeem(3, 50e18, alice, alice);
        vm.stopPrank();

        vault.setUnlocked(80e18);
        assertEq(vault.claimableRedeemRequest(1, alice), 50e18);
        assertEq(vault.claimableRedeemRequest(2, alice), 50e18);
        assertEq(vault.maxRedeem(alice), 80e18, "sum is capped at unlocked");

        vm.prank(alice);
        vault.redeem(80e18, alice, alice);
        assertEq(vault.claimableRedeemRequest(1, alice), 0, "first leftover is exhausted");
        assertEq(
            vault.claimableRedeemRequest(2, alice) + vault.pendingRedeemRequest(2, alice),
            20e18,
            "FIFO stopped at the unlocked budget"
        );

        // the mock's unlocked is sticky; once it falls, the leftover is pending, not still claimable
        vault.setUnlocked(0);
        assertEq(vault.claimableRedeemRequest(2, alice), 0);
        assertEq(vault.pendingRedeemRequest(2, alice), 20e18);
    }

    // --- redeem / withdraw execution ---

    function test_redeem_transfersAssetsAndBurnsShares() public {
        vault.setUnlocked(1_000e18);
        vm.startPrank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540AsyncRedeem.RedeemRequestConsumed(id, alice, 400e18, 0);
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

    function test_maxInstantRedeem_capByInstantUnlocked() public {
        vault.setUnlocked(700e18);
        assertEq(vault.maxInstantRedeem(alice), 700e18); // min(balance 1000, unlocked 700)
        assertEq(vault.maxRedeem(alice), 0, "no request, so nothing is claimable");

        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);
        // instantUnlocked = unlocked - redemptionQueue = 700 - 200 = 500; balance now 800
        assertEq(vault.maxInstantRedeem(alice), 500e18);
        assertEq(vault.maxRedeem(alice), 200e18, "the queued request is fully claimable");
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
        // bob is the controller
        assertEq(vault.claimableRedeemRequest(id, bob), 300e18);
    }

    /// @dev ERC-7540 allows a share allowance to stand in for the owner when a redeem request is
    /// made, but requires controller or operator to claim one. Honouring an allowance on the claim
    /// let a spender take the settled payout to an address of their choosing: the queued burn comes
    /// from the vault rather than the controller, so nothing checked the controller's balance —
    /// and queueing drops that balance to zero, which is exactly the point an outstanding approval
    /// looks spent. An infinite one is never deducted, so the ceiling was the whole position.
    function test_allowanceDoesNotAuthoriseClaimingAQueuedRedemption() public {
        vault.setUnlocked(1_000e18);

        // the approval alice would reason about as covering 300 shares of transfer
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(300e18, alice, alice);
        assertEq(vault.balanceOf(alice), 700e18, "the queued shares have left her balance");
        assertEq(vault.claimableRedeemRequest(id, alice), 300e18, "and are hers to claim");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, bob));
        vault.redeem(id, 300e18, bob, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, bob));
        vault.withdraw(id, 300e18, bob, alice);

        assertEq(asset.balanceOf(bob), 0, "bob took nothing");

        // and the claim is still alice's to make, in full
        vm.prank(alice);
        assertEq(vault.redeem(id, 300e18, alice, alice), 300e18, "her claim is intact");
        assertEq(asset.balanceOf(alice), 300e18);
    }

    /// @dev The narrowing is on the claim only. A request still accepts an allowance, since the
    /// shares genuinely leave the owner there, and an operator can still do both.
    function test_operatorStillClaimsAndAllowanceStillRequests() public {
        vault.setUnlocked(1_000e18);

        vm.startPrank(alice);
        vault.approve(bob, 300e18);
        vault.setOperator(carol, true);
        vm.stopPrank();

        vm.prank(bob);
        uint256 id = vault.requestRedeem(300e18, alice, alice);

        vm.prank(carol);
        assertEq(vault.redeem(id, 300e18, alice, alice), 300e18, "the operator claims for her");
        assertEq(asset.balanceOf(alice), 300e18);
    }

    function test_withdraw_exceedingClaimable_reverts() public {
        vault.setUnlocked(300e18);
        vm.startPrank(alice);
        uint256 id = vault.requestRedeem(1_000e18, alice, alice);
        vm.expectRevert();
        vault.withdraw(id, 301e18, alice, alice);
        vm.stopPrank();
    }

    // --- instant ERC4626 path (no request) hits the 5-arg _withdraw override ---

    function test_instantRedeem_whenLiquid() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 assets = vault.instantRedeem(400e18, alice, alice);

        assertEq(assets, 400e18);
        assertEq(asset.balanceOf(alice), 400e18);
        assertEq(vault.balanceOf(alice), 600e18);
        assertEq(vault.totalSupply(), 600e18);
    }

    function test_instantWithdraw_whenLiquid() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 shares = vault.instantWithdraw(250e18, alice, alice);

        assertEq(shares, 250e18);
        assertEq(asset.balanceOf(alice), 250e18);
        assertEq(vault.balanceOf(alice), 750e18);
    }

    function test_instantRedeem_byOperator() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        uint256 assets = vault.instantRedeem(100e18, bob, alice);
        assertEq(assets, 100e18);
        assertEq(asset.balanceOf(bob), 100e18);
        assertEq(vault.balanceOf(alice), 900e18);
    }

    function test_previewRedeemAndWithdraw_revert() public {
        vm.expectRevert(IERC7540AsyncRedeem.PreviewNotSupported.selector);
        vault.previewRedeem(1);
        vm.expectRevert(IERC7540AsyncRedeem.PreviewNotSupported.selector);
        vault.previewWithdraw(1);
    }

    function test_threeArgRedeem_claimsTheRequest() public {
        vault.setUnlocked(1_000e18);
        vm.startPrank(alice);
        vault.requestRedeem(400e18, alice, alice);
        assertEq(vault.maxRedeem(alice), 400e18);
        uint256 assets = vault.redeem(400e18, alice, alice);
        vm.stopPrank();

        assertEq(assets, 400e18);
        assertEq(asset.balanceOf(alice), 400e18);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function test_threeArgWithdraw_claimsFifoAcrossRequests() public {
        vault.setUnlocked(500e18);
        vm.startPrank(alice);
        vault.requestRedeem(400e18, alice, alice);
        vault.requestRedeem(400e18, alice, alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540AsyncRedeem.RedeemRequestConsumed(1, alice, 400e18, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540AsyncRedeem.RedeemRequestConsumed(2, alice, 100e18, 300e18);
        uint256 shares = vault.withdraw(500e18, alice, alice);
        vm.stopPrank();

        assertEq(shares, 500e18);
        assertEq(asset.balanceOf(alice), 500e18, "paid the requested assets");
        assertEq(vault.claimableRedeemRequest(1, alice), 0, "the older request is fully claimed");
        assertEq(
            vault.claimableRedeemRequest(2, alice) + vault.pendingRedeemRequest(2, alice),
            300e18,
            "the newer request still holds the rest"
        );
    }

    /// @dev Confirmed: one underlying atom across 1-share receipts burned the ceil quote and paid
    /// nothing, because each fragment's convertToAssets floored to zero and withdraw ignored the
    /// summed payout. The vault is below par so that floor is real.
    function test_threeArgWithdraw_paysTheAtomAcrossDustReceipts() public {
        vault.setUnlocked(1_000e18);
        deal(address(asset), address(vault), 400e18);
        assertEq(vault.convertToAssets(1), 0, "a single share pays nothing");

        vm.startPrank(alice);
        vault.requestRedeem(1, alice, alice);
        vault.requestRedeem(1, alice, alice);
        vault.requestRedeem(1, alice, alice);
        vault.requestRedeem(10e18, alice, alice);

        uint256 shares = vault.quoteWithdraw(1);
        assertEq(shares, 3, "the ceil quote spans the three dust receipts");
        assertEq(
            vault.convertToAssets(1) + vault.convertToAssets(1) + vault.convertToAssets(1),
            0,
            "fragment floors would have paid zero"
        );

        uint256 burned = vault.withdraw(1, alice, alice);
        vm.stopPrank();

        assertEq(burned, shares, "all quoted shares were consumed");
        assertEq(asset.balanceOf(alice), 1, "paid the atom");
        assertEq(vault.claimableRedeemRequest(1, alice) + vault.pendingRedeemRequest(1, alice), 0);
        assertEq(vault.claimableRedeemRequest(2, alice) + vault.pendingRedeemRequest(2, alice), 0);
        assertEq(vault.claimableRedeemRequest(3, alice) + vault.pendingRedeemRequest(3, alice), 0);
        assertEq(vault.claimableRedeemRequest(4, alice) + vault.pendingRedeemRequest(4, alice), 10e18);
    }

    function test_threeArgRedeem_claimsFifoAcrossRequests() public {
        vault.setUnlocked(500e18);
        vm.startPrank(alice);
        vault.requestRedeem(400e18, alice, alice);
        vault.requestRedeem(400e18, alice, alice);
        assertEq(vault.maxRedeem(alice), 500e18);
        uint256 assets = vault.redeem(500e18, alice, alice);
        vm.stopPrank();

        assertEq(assets, 500e18);
        assertEq(vault.claimableRedeemRequest(1, alice), 0, "the older request is fully claimed");
        assertEq(
            vault.claimableRedeemRequest(2, alice) + vault.pendingRedeemRequest(2, alice),
            300e18,
            "the newer request still holds the rest"
        );
    }

    function test_transferRequest_movesControlAndKeepsTheQueuePlace() public {
        vault.setUnlocked(300e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);

        assertEq(vault.claimableRedeemRequest(id, alice), 300e18);
        assertEq(vault.pendingRedeemRequest(id, alice), 100e18);

        vm.prank(alice);
        vault.transferRequest(id, bob);

        assertEq(vault.controllerOf(id), bob);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxRedeem(bob), 300e18);
        assertEq(vault.claimableRedeemRequest(id, bob), 300e18);
        assertEq(vault.pendingRedeemRequest(id, bob), 100e18);
        assertEq(vault.claimableRedeemRequest(id, alice), 0);

        vm.prank(bob);
        assertEq(vault.redeem(id, 300e18, bob, bob), 300e18);
        assertEq(asset.balanceOf(bob), 300e18);
    }

    function test_transferRequest_operatorCanMoveIt() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(200e18, alice, alice);
        vm.prank(alice);
        vault.setOperator(carol, true);

        vm.prank(carol);
        vault.transferRequest(id, bob);

        assertEq(vault.controllerOf(id), bob);
        vm.prank(bob);
        assertEq(vault.redeem(200e18, bob, bob), 200e18);
    }

    function test_transferRequest_allowanceDoesNotAuthorise() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(200e18, alice, alice);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, bob));
        vault.transferRequest(id, bob);
    }

    function test_transferRequest_unknownOrZero_reverts() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(200e18, alice, alice);

        vm.prank(alice);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroAddress.selector);
        vault.transferRequest(id, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.RedeemRequestNotFound.selector, 99, address(0)));
        vault.transferRequest(99, bob);
    }

    function test_threeArgRedeem_withoutARequest_reverts() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(400e18, alice, alice);
    }

    function test_threeArgRedeem_allowanceDoesNotAuthoriseClaim() public {
        vault.setUnlocked(1_000e18);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(alice);
        vault.requestRedeem(300e18, alice, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, bob));
        vault.redeem(300e18, bob, alice);
    }

    // --- ERC7575 / ERC165 ---

    function test_share_returnsSelf() public view {
        assertEq(vault.share(), address(vault));
    }

    function test_activeAssets_isTheUnqueuedSupply() public view {
        assertEq(vault.activeSupply(), 1_000e18);
        assertEq(vault.activeAssets(), 1_000e18);
    }

    function test_supportsInterface() public view {
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4), "EIP-7540 redeem id");
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65), "EIP-7540 operator id");
        assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5), "EIP-7575 vault id");

        assertTrue(vault.supportsInterface(type(IERC4626).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540AsyncRedeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    // --- fully pending request (no liquidity reaches it) ---

    function test_fullyPending_whenNoLiquidity() public {
        // _unlocked defaults to 0 -> nothing in the request is claimable yet
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e18, alice, alice);

        assertEq(vault.claimableRedeemRequest(id, alice), 0);
        assertEq(vault.pendingRedeemRequest(id, alice), 400e18);
    }

    // --- base unlockedSupply (no override) ---

    function test_bareVault_baseUnlockedSupplyIsZero() public {
        MockBareVault bare = new MockBareVault();
        bare.initialize(IERC20(address(asset)));

        asset.mint(bob, 100e18);
        vm.startPrank(bob);
        asset.approve(address(bare), type(uint256).max);
        bare.deposit(100e18, bob);
        vm.stopPrank();

        assertEq(bare.unlockedSupply(), 0);
        assertEq(bare.instantUnlockedSupply(), 0);
        assertEq(bare.maxRedeem(bob), 0);
        assertEq(bare.maxInstantRedeem(bob), 0);
    }
}
