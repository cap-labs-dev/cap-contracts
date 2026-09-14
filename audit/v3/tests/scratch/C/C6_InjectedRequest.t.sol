// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// Deallocation accounting: a foreign `requestRedeem(shares, controller=underwriter, owner=self)`
/// on the tranche. Verifies (a) finalize refuses it, (b) `_mark` does not count it, (c) it does
/// occupy the FIFO watermark ahead of a later underwriter request, (d) it inflates
/// `maxRedeem(underwriter)`, which the Underwriter never reads. Ties to P2 (WS-B).
contract C6_InjectedRequest is CapDeployer {
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");

    Underwriter uw;
    MarketBundle b;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        uw = _deployUnderwriter();
        _admitDepositor(b.tranche0Addr, address(uw));
        uw.addTranche(b.tranche0Addr);
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        _fundTranche(b.tranche0Addr, griefer, 300e18);
    }

    function test_injectedRequest_refusedByFinalize_notInMark_butAheadInQueue() public {
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18); // lockedValue = 714.28; unlocked = 1300 - 714.28 = 585.7

        // griefer queues 300 shares naming the underwriter as controller, before the underwriter queues
        vm.prank(griefer);
        uint256 injected = b.tranche0.requestRedeem(300e18, address(uw), griefer);

        uint256 bookBefore = uw.totalAssets();
        uint256 own = uw.deallocateAsync(b.tranche0Addr, 400e18);
        assertEq(uw.totalAssets(), bookBefore, "injected shares never enter the mark");

        console.log("unlockedSupply:                 ", b.tranche0.unlockedSupply());
        console.log("claimable(injected, uw):        ", b.tranche0.claimableRedeemRequest(injected, address(uw)));
        console.log("claimable(own, uw):             ", b.tranche0.claimableRedeemRequest(own, address(uw)));
        console.log("maxRedeem(uw) (3-arg path):     ", b.tranche0.maxRedeem(address(uw)));

        // (a) finalize refuses the foreign id
        vm.expectRevert(IUnderwriter.UnknownQueuedRequest.selector);
        uw.finalizeDeallocateAsync(b.tranche0Addr, injected, 1);

        // (c) the injected request took the first 300 of ~585 unlocked; the underwriter's own
        //     request gets only what is left. The griefer's 300 shares are stuck forever: only the
        //     controller (uw) can claim or transfer them and it has no code path to do so.
        uint256 ownClaimable = b.tranche0.claimableRedeemRequest(own, address(uw));
        assertLt(ownClaimable, 400e18, "underwriter's request is throttled by the injected one");
        uw.finalizeDeallocateAsync(b.tranche0Addr, own, ownClaimable);
        assertEq(b.tranche0.pendingRedeemRequest(own, address(uw)), 400e18 - ownClaimable);

        // once the debt is gone everything unlocks and the underwriter finishes its own request
        _mintStable(defaultBorrower, 1_000e18);
        vm.startPrank(defaultBorrower);
        b.market.repay(type(uint256).max);
        vm.stopPrank();
        uw.finalizeDeallocateAsync(b.tranche0Addr, own, 400e18 - ownClaimable);
        assertEq(uw.queuedShares(b.tranche0Addr), 0);
        // the griefer's request still sits there under the underwriter's name
        assertEq(
            b.tranche0.pendingRedeemRequest(injected, address(uw))
                + b.tranche0.claimableRedeemRequest(injected, address(uw)),
            300e18
        );
        assertEq(b.tranche0.balanceOf(griefer), 0, "griefer paid 300 shares for the delay");
    }
}
