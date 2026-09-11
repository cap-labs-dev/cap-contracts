// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IERC1155Queue } from "../../../../contracts/interfaces/IERC1155Queue.sol";
import { IERC7540AsyncRedeem } from "../../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { DeadShares } from "../../../../contracts/utils/DeadShares.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";

/// @notice Passing demonstrations that back the Informational / Low notes in B.md.
contract B_DeadSharesAndMisc is CapDeployer {
    address internal donor = makeAddr("donor");
    address internal first = makeAddr("first");
    address internal second = makeAddr("second");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    FloatingMarket internal market;
    Tranche internal senior;

    bytes32 internal constant BASE = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    function _nft(address v) internal view returns (IERC1155) {
        return IERC1155(address(uint160(uint256(vm.load(v, bytes32(uint256(BASE) + 4))))));
    }

    function setUp() public {
        _deployCap();
        (address m, address s,) = _createMarket("Market A");
        market = FloatingMarket(m);
        senior = Tranche(s);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(type(uint256).max);
    }

    // ── H15: donation before first deposit is a windfall to the first depositor ─────────────

    function test_H15_donationIsWindfallToFirstDepositor_secondDepositorUnaffected() public {
        _fundVault(donor, 1_000e18);
        vm.prank(donor);
        vault.transfer(address(senior), address(collateral), 1_000e18); // donation, no shares
        assertEq(senior.totalAssets(), 1_000e18);
        assertEq(senior.totalSupply(), 0);

        _fundTranche(address(senior), first, 1e18);
        assertEq(senior.balanceOf(first), 1e18 - DeadShares.SHARES, "quoted at par, donation ignored");
        // first depositor now owns ~all of 1001e18 of assets
        uint256 firstValue = senior.previewRedeem(senior.balanceOf(first));
        emit log_named_uint("first depositor deposited 1e18, can redeem", firstValue);
        assertGt(firstValue, 1_000e18);

        // second depositor gets a fair quote off the (now inflated) ratio
        _fundTranche(address(senior), second, 100e18);
        uint256 secondValue = senior.previewRedeem(senior.balanceOf(second));
        emit log_named_uint("second depositor deposited 100e18, can redeem", secondValue);
        assertApproxEqRel(secondValue, 100e18, 1e12, "second depositor is not diluted");

        // market capital is the real vault balance - nothing phantom
        assertEq(senior.totalCapital(), senior.totalAssets() * capConfig.collateralPrice / 1e18);
        assertEq(market.totalCapital(), 1_101e18);
    }

    /// Classic inflation attack against a live tranche is unprofitable with the seed in place.
    function test_H15_inflationAttackLosesMoney() public {
        _fundTranche(address(senior), attacker, 2e3); // attacker gets 1e3 shares, seed 1e3
        assertEq(senior.balanceOf(attacker), 1e3);

        uint256 victimDeposit = 10e18;
        // donation needed to round victim to zero: V*(S+1)/(A+D+1) < 1  => D > V*(S+1) - A - 1
        uint256 donation = victimDeposit * (senior.totalSupply() + 1);
        _fundVault(attacker, donation);
        vm.prank(attacker);
        vault.transfer(address(senior), address(collateral), donation);

        _fundTranche(address(senior), victim, victimDeposit);
        uint256 victimShares = senior.balanceOf(victim);
        emit log_named_uint("victim shares", victimShares);

        uint256 attackerOut = senior.previewRedeem(senior.balanceOf(attacker));
        uint256 attackerIn = 2e3 + donation;
        emit log_named_uint("attacker in ", attackerIn);
        emit log_named_uint("attacker out", attackerOut);
        assertLt(attackerOut, attackerIn, "attack must be unprofitable");
        // the dead seed keeps ~half of the pot away from the attacker
        assertLt(attackerOut * 2, attackerIn + victimDeposit);
    }

    /// Dead shares cannot be redeemed, requested, or transferred by anyone.
    function test_deadSharesAreUnredeemable() public {
        _fundTranche(address(senior), first, 10e18);
        assertEq(senior.balanceOf(DeadShares.HOLDER), 1e3);
        assertEq(senior.stakedSupply(), 10e18 - 1e3, "dead excluded from staked");

        vm.prank(first);
        vm.expectRevert();
        senior.redeem(1e3, first, DeadShares.HOLDER);
        vm.prank(first);
        vm.expectRevert();
        senior.requestRedeem(1e3, first, DeadShares.HOLDER);
        assertEq(senior.claimable(DeadShares.HOLDER), 0);
    }

    // ── ERC-1155 receipt transfer: no double claim, wrong-party pay, or zero-backed receipt ──

    function test_receiptTransfer_movesClaimEntirely_noDoubleClaim() public {
        _fundTranche(address(senior), first, 100e18);
        uint256 shares = senior.balanceOf(first);
        vm.prank(first);
        uint256 id = senior.requestRedeem(shares, first, first);
        IERC1155 nft = _nft(address(senior));

        // split 60/40 with `second`
        vm.prank(first);
        nft.safeTransferFrom(first, second, id, 40e18, "");

        assertEq(senior.claimableRedeemRequest(id, first), shares - 40e18);
        assertEq(senior.claimableRedeemRequest(id, second), 40e18);

        vm.prank(second);
        senior.redeem(id, 40e18, second, second);
        vm.prank(first);
        senior.redeem(id, shares - 40e18, first, first);

        // nothing left for either, vault holds no queued shares
        assertEq(senior.claimableRedeemRequest(id, first), 0);
        assertEq(senior.claimableRedeemRequest(id, second), 0);
        assertEq(senior.balanceOf(address(senior)), 0);
        assertEq(senior.redemptionQueue(), 0);
        vm.prank(first);
        vm.expectRevert();
        senior.redeem(id, 1, first, first);
    }

    /// An allowance on shares does not let the spender claim a queued position (confirmed).
    function test_allowanceCannotClaimQueuedPosition() public {
        _fundTranche(address(senior), first, 100e18);
        uint256 shares = senior.balanceOf(first);
        vm.startPrank(first);
        senior.approve(attacker, type(uint256).max);
        uint256 id = senior.requestRedeem(shares, first, first);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, attacker));
        senior.redeem(id, shares, attacker, first);
    }

    // ── instantUnlockedSupply never underflows when the queue exceeds liquidity ───────────

    function test_instantUnlocked_zeroNotRevert_whenQueueExceedsUnlocked() public {
        _mintStable(first, 100e18); // credit-backed: unlocked = 0
        vm.prank(first);
        stablecoin.requestRedeem(100e18, first, first);
        assertEq(stablecoin.redemptionQueue(), 100e18);
        assertEq(stablecoin.unlockedSupply(), 0);
        assertEq(stablecoin.instantUnlockedSupply(), 0);
        assertEq(stablecoin.maxRedeem(first), 0);
        assertEq(stablecoin.maxWithdraw(first), 0);
    }

    // ── ghost controller: request with a controller nobody controls strands the shares ─────

    function test_ghostController_strandsSharesAtQueueHead_noCancel() public {
        _fundTranche(address(senior), first, 100e18);
        _fundTranche(address(senior), second, 100e18);
        address ghost = address(0xdead1);
        vm.prank(first);
        uint256 idGhost = senior.requestRedeem(50e18, ghost, first); // EOA-like, no code: mint succeeds
        assertEq(senior.claimableRedeemRequest(idGhost, ghost), 50e18);

        // nobody can ever claim it; and `first` cannot cancel or reclaim
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(IERC7540AsyncRedeem.NotAuthorized.selector, first));
        senior.redeem(idGhost, 50e18, first, ghost);

        // the ghost's window sits at the head; a later request needs 50e18 MORE liquidity than
        // it otherwise would (positional queue), forever
        vm.prank(second);
        uint256 idS = senior.requestRedeem(100e18, second, second);
        assertEq(senior.claimableRedeemRequest(idS, second), 100e18, "plenty unlocked today");
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("unlocked after max borrow", senior.unlockedSupply());
        emit log_named_uint("second claimable         ", senior.claimableRedeemRequest(idS, second));
        emit log_named_uint("instantUnlockedSupply    ", senior.instantUnlockedSupply());
    }

    // ── direct ERC-20 transfer of shares to the vault breaks I13's second clause ───────────

    function test_donatedSharesToVault_countAsStakedButEarnNobody() public {
        _fundTranche(address(senior), first, 100e18);
        vm.prank(first);
        senior.transfer(address(senior), 10e18);
        assertEq(senior.balanceOf(address(senior)), 10e18);
        assertEq(senior.redemptionQueue(), 0, "not in the queue");
        assertEq(senior.stakedSupply(), 100e18 - 1e3, "donated shares still count as staked");
    }

    // ── contract controllers must implement ERC1155Receiver (documented) ──────────────────

    function test_contractControllerWithoutReceiver_reverts() public {
        _fundTranche(address(senior), first, 100e18);
        vm.prank(first);
        vm.expectRevert();
        senior.requestRedeem(1e18, address(senior), first); // the vault itself has no receiver
        vm.prank(first);
        vm.expectRevert();
        senior.requestRedeem(1e18, address(market), first);
    }

    // ── supportsInterface claims IERC1155Queue but the vault has no such functions ─────────

    function test_supportsInterface_misreportsIERC1155Queue() public view {
        assertTrue(senior.supportsInterface(type(IERC1155Queue).interfaceId));
        (bool ok,) = address(senior).staticcall(abi.encodeWithSelector(IERC1155.balanceOf.selector, first, 0));
        assertFalse(ok, "balanceOf(address,uint256) is not implemented by the vault");
    }
}
