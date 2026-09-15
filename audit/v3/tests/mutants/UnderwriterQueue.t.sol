// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice Killing tests for the Underwriter's queued-deallocation bookkeeping and default-tranche
/// handling. The stock suite only ever queues and settles a *whole* position once, and only ever
/// removes the tranche that is also the default.
///
/// Gambit `Underwriter#33` (`if (shares > balance)` → always) queues the whole balance whatever
/// the allocator asked; `#37` zeroes an oversize request instead of clamping it; `#53`/`#57`/`#61`
/// corrupt `queuedRequest[tranche][id]` after a partial settlement; `#17` clears the default on
/// every removal.
contract UnderwriterQueueKillTest is CapDeployer {
    address internal alice = makeAddr("alice");
    Underwriter internal uw;
    MarketBundle internal b;

    function setUp() public {
        _deployCap();
        uw = _deployUnderwriter();
        b = _createReadyMarket("uw");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(b.tranche0Addr, address(uw));
        _fundUnderwriter(address(uw), alice, 1_000e18);
    }

    /// Kills Underwriter#33 and #37.
    function test_deallocateAsyncQueuesWhatWasAskedAndClampsOversize() public {
        uint256 held = b.tranche0.balanceOf(address(uw));
        assertGt(held, 0);

        uint256 id = uw.deallocateAsync(b.tranche0Addr, held / 4);
        assertEq(uw.queuedShares(b.tranche0Addr), held / 4, "a quarter is queued, not the whole position");
        assertEq(uw.queuedRequest(b.tranche0Addr, id), held / 4);
        assertEq(b.tranche0.balanceOf(address(uw)), held - held / 4, "three quarters stay allocated");

        uint256 id2 = uw.deallocateAsync(b.tranche0Addr, held * 10);
        assertEq(uw.queuedRequest(b.tranche0Addr, id2), held - held / 4, "an oversize request clamps to the balance");
        assertEq(uw.queuedShares(b.tranche0Addr), held, "everything is now queued");
        assertEq(b.tranche0.balanceOf(address(uw)), 0);
    }

    /// Kills Underwriter#53, #57, #61.
    function test_partialFinalizeDecrementsTheRecordedRequest() public {
        uint256 held = b.tranche0.balanceOf(address(uw));
        uint256 id = uw.deallocateAsync(b.tranche0Addr, held);
        assertEq(b.tranche0.claimableRedeemRequest(id, address(uw)), held, "nothing is borrowed, so all claimable");

        uint256 valued = uw.totalAssets();
        uw.finalizeDeallocateAsync(b.tranche0Addr, id, held / 3);
        assertEq(uw.queuedRequest(b.tranche0Addr, id), held - held / 3, "the request records the remainder");
        assertEq(uw.queuedShares(b.tranche0Addr), held - held / 3, "and so does the aggregate");
        assertApproxEqAbs(uw.totalAssets(), valued, 2, "settling moves assets home, not the valuation");

        uw.finalizeDeallocateAsync(b.tranche0Addr, id, held - held / 3);
        assertEq(uw.queuedRequest(b.tranche0Addr, id), 0);
        assertEq(uw.queuedShares(b.tranche0Addr), 0);
        assertEq(uw.totalDebt(), 0, "nothing is recorded against an exited tranche");
        assertApproxEqAbs(uw.totalAssets(), valued, 2);
    }

    /// Kills Underwriter#17: removing a tranche that is not the default leaves the default alone.
    function test_removingANonDefaultTrancheKeepsTheDefault() public {
        uw.addTranche(b.tranche1Addr);
        assertEq(uw.defaultTranche(), b.tranche0Addr);

        uw.removeTranche(b.tranche1Addr);

        assertEq(uw.defaultTranche(), b.tranche0Addr, "the default survives an unrelated removal");
        assertFalse(vault.isOperator(address(uw), b.tranche1Addr));
        assertTrue(vault.isOperator(address(uw), b.tranche0Addr));
    }
}
