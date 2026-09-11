// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Adversarial verification of MED-JIT-PREMIUM. Probes the angles the WS-C PoC does not cover.
contract V_JitPremium is CapDeployer {
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        _deployCap();
    }

    /// (b) Front-running is not needed: a depositor arriving 1h AFTER the borrow still takes
    /// 50% of the remaining 5/6 of the lump. Mempool visibility is irrelevant; the window is 6h.
    function test_backrun_oneHourLate_stillCaptures() public {
        (address m, address t0,) = _createFixedMarket("F");
        _setMarketSlopes(m);
        _fundTranche(t0, alice, 1000e18);

        vm.prank(defaultBorrower);
        FixedMarket(m).borrow(defaultBorrower, 400e18, 30 days);
        uint256 lump = stablecoin.balanceOf(t0);

        vm.warp(block.timestamp + 1 hours);
        _fundTranche(t0, carol, 1000e18); // back-run, one hour late
        vm.warp(block.timestamp + 5 hours + 1);

        vm.prank(carol);
        uint256 carolGot = Tranche(t0).claim(carol);
        emit log_named_uint("lump", lump);
        emit log_named_uint("carol (arrived 1h late) claimed", carolGot);
        emit log_named_uint("expected ~ lump * 5/6 * 1/2", lump * 5 / 12);
        assertApproxEqRel(carolGot, lump * 5 / 12, 1e15);

        uint256 bal = Tranche(t0).balanceOf(carol);
        vm.prank(carol);
        uint256 out = Tranche(t0).redeem(bal, carol, carol);
        emit log_named_uint("carol redeemed", out);
        assertEq(out, 1000e18);
    }

    /// (d) Junior tranche: lockedValue for the most junior tranche is the FULL debt/(lt-buffer),
    /// yet with carol doubling the tranche there is still headroom to exit 100%.
    function test_juniorTranche_alsoExits() public {
        (address m, address t0, address t1) = _createFixedMarket("F");
        _setMarketSlopes(m);
        _fundTranche(t0, makeAddr("seniorLp"), 1000e18); // senior sits at 1000
        _fundTranche(t1, alice, 1000e18);
        _fundTranche(t1, carol, 1000e18);

        vm.prank(defaultBorrower);
        FixedMarket(m).borrow(defaultBorrower, 500e18, 30 days);
        uint256 juniorLump = stablecoin.balanceOf(t1);
        emit log_named_uint("junior lump (5% weight of underwriter premium)", juniorLump);

        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = Tranche(t1).claim(carol);
        emit log_named_uint("junior carol claimed", carolGot);
        emit log_named_uint("junior instantUnlockedSupply", Tranche(t1).instantUnlockedSupply());
        emit log_named_uint("junior maxRedeem(carol)", Tranche(t1).maxRedeem(carol));
        uint256 bal = Tranche(t1).balanceOf(carol);
        vm.prank(carol);
        uint256 out = Tranche(t1).redeem(bal, carol, carol);
        assertEq(out, 1000e18, "junior carol exits in full");
    }

    /// (a) The vesting period is a curator knob. With it set to the term, the 6h JIT take drops
    /// from 50% of the lump to ~ 50% * 6h/30d. This shows the mitigation exists in-tree as a
    /// parameter, but see the restart caveat in the next test.
    function test_vestOverTerm_knob_defeatsSixHourJit() public {
        (address m, address t0,) = _createFixedMarket("F");
        _setMarketSlopes(m);
        vm.prank(defaultMarketOwner);
        Tranche(t0).setVestingPeriod(30 days);

        _fundTranche(t0, alice, 1000e18);
        _fundTranche(t0, carol, 1000e18);
        vm.prank(defaultBorrower);
        FixedMarket(m).borrow(defaultBorrower, 500e18, 30 days);
        uint256 lump = stablecoin.balanceOf(t0);

        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = Tranche(t0).claim(carol);
        emit log_named_uint("carol claimed at 6h with 30d vest", carolGot);
        emit log_named_uint("as bps of lump", carolGot * 10000 / lump);
        assertLt(carolGot * 10000 / lump, 50); // < 0.5% of the lump
    }

    /// (e) Restart caveat: with a 30d vest, every later borrow restarts the epoch and re-spreads
    /// what was still locked over a fresh 30d to CURRENT holders. Carol arriving at day 15 before
    /// a second borrow ends up sharing alice's locked half of lump #1. Is that a loss? The locked
    /// half pays for days 15-30 of risk, which carol does carry from day 15 on. So attribution is
    /// right; only the *timing* is stretched (C8). This test measures it.
    function test_restart_reVestsLockedToNewHolder() public {
        (address m, address t0,) = _createFixedMarket("F");
        _setMarketSlopes(m);
        vm.prank(defaultMarketOwner);
        Tranche(t0).setVestingPeriod(30 days);

        _fundTranche(t0, alice, 1000e18);
        vm.prank(defaultBorrower);
        FixedMarket(m).borrow(defaultBorrower, 250e18, 30 days);
        uint256 lump1 = stablecoin.balanceOf(t0);

        vm.warp(block.timestamp + 15 days);
        _fundTranche(t0, carol, 1000e18);
        vm.prank(defaultBorrower);
        FixedMarket(m).borrow(defaultBorrower, 250e18, 30 days); // restart: locked lump1/2 + lump2
        uint256 lump2 = stablecoin.balanceOf(t0) - lump1;

        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(carol);
        uint256 carolGot = Tranche(t0).claim(carol);
        vm.prank(alice);
        uint256 aliceGot = Tranche(t0).claim(alice);
        emit log_named_uint("lump1", lump1);
        emit log_named_uint("lump2", lump2);
        emit log_named_uint("alice total", aliceGot);
        emit log_named_uint("carol total", carolGot);
        // carol: half of (lump1/2 + lump2); alice: lump1/2 + half of (lump1/2 + lump2)
        assertApproxEqRel(carolGot, (lump1 / 2 + lump2) / 2, 1e12);
        assertApproxEqRel(aliceGot, lump1 / 2 + (lump1 / 2 + lump2) / 2, 1e12);
    }

    /// (a) Underwriter case: the JIT depositor CANNOT self-exit. Deposits auto-allocate to the
    /// default tranche, unlockedSupply reads the idle vault balance, so maxRedeem is 0 and only
    /// the curator's deallocate frees her. She keeps carrying risk after collecting.
    function test_underwriterJit_cannotSelfExit() public {
        MarketBundle memory b = _createReadyMarket("M");
        Underwriter uw = _deployUnderwriter();
        _admitDepositor(address(b.tranche0), address(uw));
        uw.addTranche(address(b.tranche0));
        uw.setDefaultTranche(address(b.tranche0));

        _fundUnderwriter(address(uw), alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 6 hours + 1);

        // share price seen by carol ignores the tranche's claimable premium
        uint256 claimableBefore = b.tranche0.claimable(address(uw));
        uint256 sharesForCarol = uw.previewDeposit(1000e18);
        emit log_named_uint("tranche claimable owed to underwriter, unpriced in uw shares", claimableBefore);
        emit log_named_uint("uw shares quoted to carol for 1000", sharesForCarol);

        _fundUnderwriter(address(uw), carol, 1000e18);
        uw.report(address(b.tranche0));
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = uw.claim();
        emit log_named_uint("carol claimed", carolGot);
        emit log_named_uint("uw.maxRedeem(carol)", uw.maxRedeem(carol));
        assertEq(uw.maxRedeem(carol), 0, "carol cannot instant-redeem from the underwriter");
        uint256 bal = uw.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert();
        uw.redeem(bal, carol, carol);
    }

    /// Early repay does not refund the term premium, so the 30d lump is final the moment it is
    /// minted. The borrower's own economics do not claw anything back from the JIT depositor.
    function test_earlyRepay_noRefund() public {
        (address m, address t0,) = _createFixedMarket("F");
        _setMarketSlopes(m);
        _fundTranche(t0, alice, 1000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = FixedMarket(m).borrow(defaultBorrower, 400e18, 30 days);
        uint256 lump = stablecoin.balanceOf(t0);
        uint256 debt = FixedMarket(m).debt(id);
        emit log_named_uint("debt right after borrow (principal + full-term premium)", debt);
        vm.warp(block.timestamp + 1 days);
        _mintStable(defaultBorrower, debt);
        vm.startPrank(defaultBorrower);
        stablecoin.approve(m, debt);
        FixedMarket(m).repay(id, debt);
        vm.stopPrank();
        assertEq(stablecoin.balanceOf(t0), lump, "tranche keeps the whole lump after early repay");
        assertEq(FixedMarket(m).debt(id), 0);
    }
}
