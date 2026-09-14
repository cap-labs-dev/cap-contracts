// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// WS-E / P12: reserve-loss recognition is a GUARDIAN mempool tx; between the loss and the tx
// landing, every pricing surface quotes par and instantRedeem pays par from the recalled
// balance. Whoever exits first is whole; the loss lands 100% on the remaining holders.

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAeraVault } from "../../../../../test/shared/mocks/MockAeraVault.sol";
import { console } from "forge-std/console.sol";

contract E_P12_FrontRun is CapDeployer {
    MockAeraVault internal aera;
    address internal h1 = makeAddr("holder1");
    address internal h2 = makeAddr("holder2");
    address internal h3 = makeAddr("holder3");
    uint256 internal constant D = 100e18;

    function setUp() public {
        _deployCap();
        aera = new MockAeraVault();
        stablecoin.setReserveVault(address(aera)); // GOVERNOR
        _depositStable(h1, D);
        _depositStable(h2, D);
        _depositStable(h3, D);
    }

    /// Redeem everything the holder can; after recognition each call is capped at
    /// supply - badDebt shares, so the tail holder needs a few calls.
    function _exit(address who) internal returns (uint256 got) {
        uint256 before = cusdUnderlying.balanceOf(who);
        for (uint256 i; i < 40; ++i) {
            uint256 shares = stablecoin.maxInstantRedeem(who);
            if (shares == 0) break;
            vm.prank(who);
            stablecoin.instantRedeem(shares, who, who);
        }
        got = cusdUnderlying.balanceOf(who) - before;
    }

    /// KEEPER `invest` is uncapped: investing the whole reserve zeroes unlockedSupply and freezes
    /// every redemption path (instant and queued) while totalAssets still reports full backing.
    function test_investAll_freezesRedemptions_noCap() public {
        stablecoin.invest(3 * D); // KEEPER
        assertEq(stablecoin.unlockedSupply(), 0, "nothing redeemable");
        assertEq(stablecoin.maxInstantRedeem(h1), 0);
        assertEq(stablecoin.maxRedeem(h1), 0);
        assertEq(stablecoin.totalAssets(), 3 * D, "still reports full backing");
        vm.prank(h1);
        vm.expectRevert();
        stablecoin.instantRedeem(1, h1, h1);
    }

    /// recall reverts once Aera is short; holders stay frozen until keeper recalls what is left.
    function test_recall_revertsWhenAeraIsShort() public {
        stablecoin.invest(3 * D);
        cusdUnderlying.burn(address(aera), 90e18); // 30% loss on the reserve leg
        vm.expectRevert();
        stablecoin.recall(3 * D);
        assertEq(stablecoin.unlockedSupply(), 0);
        stablecoin.recall(210e18);
        assertEq(stablecoin.unlockedSupply(), 210e18);
    }

    /// The property that should hold: after a 30% reserve loss no holder exits with more than
    /// its pro-rata share (70). Fails on current code: holder 1 exits at par (100) in the block
    /// before `recognizeBadDebtInReserve` lands; holders 2-3 absorb the whole 90.
    function test_P12_frontRunRecognition_firstExiterWhole_restAbsorbAll() public {
        stablecoin.invest(3 * D);
        cusdUnderlying.burn(address(aera), 90e18);
        stablecoin.recall(210e18);

        // pre-recognition: every surface quotes par
        assertEq(stablecoin.convertToAssets(D), D, "par");
        assertEq(stablecoin.maxInstantWithdraw(h1), D, "maxInstantWithdraw par");
        assertEq(stablecoin.totalAssets(), 3 * D, "totalAssets overstated");
        assertEq(stablecoin.badDebt(), 0);

        // same block, ahead of the guardian tx
        uint256 got1 = _exit(h1);
        // guardian tx lands
        stablecoin.recognizeBadDebtInReserve(90e18);
        uint256 got2 = _exit(h2);
        uint256 got3 = _exit(h3);

        console.log("holder1 (front-ran) received:", got1);
        console.log("holder2 received:            ", got2);
        console.log("holder3 received:            ", got3);
        console.log("sum:                         ", got1 + got2 + got3);
        console.log("stablecoin underlying left:  ", cusdUnderlying.balanceOf(address(stablecoin)));
        console.log("badDebt after drain:         ", stablecoin.badDebt());
        console.log("supply after drain:          ", stablecoin.totalSupply());

        assertEq(got1 + got2 + got3, 210e18, "conserved");
        assertEq(got1, D, "front-runner paid par");
        assertEq(got2 + got3, 110e18, "the other two absorb the full 90");
        // the pro-rata property, expected to FAIL
        assertLe(got1, 70e18, "no holder should exit above pro-rata after a reserve loss");
    }

    /// Queue path: identical ordering effect via 4-arg redeem. h1's queued claim settles at par
    /// before recognition. After recognition the tail redeemer needs repeated claims (each call
    /// unlocks only supply-badDebt shares) but is eventually paid everything on hand.
    function test_P12_queueDrain_orderAndTailIterations() public {
        vm.prank(h1);
        uint256 r1 = stablecoin.requestRedeem(D, h1, h1);
        vm.prank(h2);
        uint256 r2 = stablecoin.requestRedeem(D, h2, h2);
        vm.prank(h3);
        uint256 r3 = stablecoin.requestRedeem(D, h3, h3);

        stablecoin.invest(3 * D);
        assertEq(stablecoin.claimableRedeemRequest(r1, h1), 0, "frozen while invested");
        cusdUnderlying.burn(address(aera), 90e18);
        stablecoin.recall(210e18);

        // pre-recognition: h1 and h2 fully claimable at par, h3 gets 10 at par
        assertEq(stablecoin.claimableRedeemRequest(r1, h1), D);
        assertEq(stablecoin.claimableRedeemRequest(r2, h2), D);
        assertEq(stablecoin.claimableRedeemRequest(r3, h3), 10e18);
        vm.prank(h1);
        uint256 got1 = stablecoin.redeem(r1, D, h1, h1);
        assertEq(got1, D, "h1 queued claim at par before recognition");

        stablecoin.recognizeBadDebtInReserve(90e18);

        uint256 c2 = stablecoin.claimableRedeemRequest(r2, h2);
        vm.prank(h2);
        uint256 got2 = stablecoin.redeem(r2, c2, h2, h2);

        uint256 got3;
        uint256 iters;
        while (stablecoin.claimableRedeemRequest(r3, h3) > 0) {
            uint256 c = stablecoin.claimableRedeemRequest(r3, h3);
            vm.prank(h3);
            got3 += stablecoin.redeem(r3, c, h3, h3);
            iters++;
            if (iters > 50) break;
        }
        console.log("queue: h1", got1, "h2", got2);
        console.log("queue: h3", got3, "iterations", iters);
        console.log(
            "queue: left on hand", cusdUnderlying.balanceOf(address(stablecoin)), "badDebt", stablecoin.badDebt()
        );
        console.log(
            "queue: remaining shares in r3",
            stablecoin.pendingRedeemRequest(r3, h3) + stablecoin.claimableRedeemRequest(r3, h3)
        );
        assertEq(got1 + got2 + got3, 210e18, "everything on hand is paid out");
        assertLt(iters, 50, "tail converges");
    }

    /// previewDeposit is par during a shortfall: a newcomer instantly loses badDebt/(S+D) of
    /// backing and more on the exit curve. States the number.
    function test_depositDuringShortfall_immediateLoss() public {
        stablecoin.invest(3 * D);
        cusdUnderlying.burn(address(aera), 90e18);
        stablecoin.recall(210e18);
        stablecoin.recognizeBadDebtInReserve(90e18);

        address newcomer = makeAddr("newcomer");
        _depositStable(newcomer, D);
        assertEq(stablecoin.balanceOf(newcomer), D, "minted at par");
        uint256 exitQuote = stablecoin.convertToAssets(D);
        uint256 backingPerShare = stablecoin.totalAssets() * 1e18 / stablecoin.totalSupply();
        console.log("newcomer exit quote for 100:", exitQuote);
        console.log("backing per share (1e18):   ", backingPerShare);
        console.log("newcomer backing loss %:     ", (1e18 - backingPerShare) * 100 / 1e18);
        assertLt(exitQuote, D);
    }

    /// GUARDIAN honest mistake: over-recognising has no reversal path. Early exiters are
    /// haircut although the reserve is whole; the surplus is stranded in the contract.
    function test_overRecognition_isIrreversible_strandsSurplus() public {
        // no loss at all, guardian recognises 90 by mistake
        stablecoin.recognizeBadDebtInReserve(90e18);
        uint256 got1 = _exit(h1);
        uint256 got2 = _exit(h2);
        uint256 got3 = _exit(h3);
        console.log("no-loss over-recognition: h1", got1, "h2", got2);
        console.log("no-loss over-recognition: h3", got3, "stranded", cusdUnderlying.balanceOf(address(stablecoin)));
        assertEq(stablecoin.totalSupply(), 0);
        assertGt(cusdUnderlying.balanceOf(address(stablecoin)), 0, "surplus stranded, no sweep");
        assertLt(got1, D, "h1 haircut although reserve is whole");
    }
}
