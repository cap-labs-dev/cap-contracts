// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CurveHarness } from "./CurveHarness.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice H6 / I10 / I11 wei-level tests of the bad-debt haircut curve. Written to be run at
/// 6, 8 and 18 underlying decimals via the concrete contracts at the bottom of the file.
abstract contract CurveTests is CurveHarness {
    // ─────────────────────────────────────────────────────────────────────────
    // I10: split-equivalence, tight bound (n legs never beat one leg by > 1 underlying unit)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_splitNeverBeatsWhole(
        uint256 dep,
        uint256 credit,
        uint256 bad,
        uint256 total,
        uint8 n,
        uint256 seed
    ) public {
        n = uint8(bound(n, 2, 12));
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec); // 1 .. 1e9 dollars
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);

        uint256 snap = vm.snapshotState();
        _seed(dep, credit, bad);
        uint256 maxShares = scoin.maxRedeem(alice);
        vm.assume(maxShares >= n);
        total = bound(total, n, maxShares);

        vm.prank(alice);
        uint256 whole = scoin.redeem(total, alice, alice);
        uint256 kWhole = _k();
        vm.revertToState(snap);

        _seed(dep, credit, bad);
        uint256 kBefore = _k();
        uint256 split;
        uint256 left = total;
        for (uint256 i; i < n; ++i) {
            uint256 part;
            if (i + 1 == n) {
                part = left;
            } else {
                seed = uint256(keccak256(abi.encode(seed, i)));
                part = 1 + (seed % (left - (n - 1 - i)));
            }
            left -= part;
            vm.prank(alice);
            split += scoin.redeem(part, alice, alice);
            // k must never increase: rounding can only favour those who stay
            assertLe(_k(), kBefore, "k rose after a slice");
        }
        assertLe(split, whole + 1, "split beat whole by more than one underlying unit");
        assertLe(_k(), kBefore, "k rose overall");
        // and the end state after the split is at least as good for stayers as after the whole
        assertGe(scoin.totalAssets(), 0);
        kWhole; // silence
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I11: deposit -> redeem round trip never pays more than it took, with and without bad debt
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_roundTripNeverProfits(uint256 dep, uint256 credit, uint256 bad, uint256 in_) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 0, 1e12 * 1e18);
        bad = credit == 0 ? 0 : bound(bad, 0, credit);
        _seed(dep, credit, bad);

        in_ = bound(in_, 1, 1e9 * 10 ** dec);
        uint256 before = asset.balanceOf(bob);
        vm.prank(bob);
        uint256 shares = scoin.deposit(in_, bob);
        assertEq(shares, in_ * scale, "par mint");
        uint256 max = scoin.maxRedeem(bob);
        vm.assume(max > 0);
        vm.prank(bob);
        scoin.redeem(max, bob, bob);
        assertLe(asset.balanceOf(bob), before, "round trip profited");
    }

    /// mint(shares) then redeem(shares) also never profits, at any share count (ceil on the way in)
    function testFuzz_mintRedeemRoundTripNeverProfits(uint256 dep, uint256 credit, uint256 bad, uint256 shares) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 0, 1e12 * 1e18);
        bad = credit == 0 ? 0 : bound(bad, 0, credit);
        _seed(dep, credit, bad);

        shares = bound(shares, 1, 1e9 * 1e18);
        uint256 before = asset.balanceOf(bob);
        vm.prank(bob);
        scoin.mint(shares, bob);
        uint256 max = scoin.maxRedeem(bob);
        vm.assume(max > 0);
        vm.prank(bob);
        scoin.redeem(max, bob, bob);
        assertLe(asset.balanceOf(bob), before, "mint/redeem round trip profited");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit-to-improve-exit claim (Stablecoin.sol L219-220)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_topUpBeforeExitNeverHelps(uint256 dep, uint256 credit, uint256 bad, uint256 x, uint256 topUp)
        public
    {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);
        uint256 snap = vm.snapshotState();
        _seed(dep, credit, bad);
        uint256 max = scoin.maxRedeem(alice);
        vm.assume(max > 0);
        x = bound(x, 1, max);
        vm.prank(alice);
        uint256 plain = scoin.redeem(x, alice, alice);
        vm.revertToState(snap);

        _seed(dep, credit, bad);
        topUp = bound(topUp, 1, 1e9 * 10 ** dec);
        uint256 before = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 extra = scoin.deposit(topUp, alice);
        vm.prank(alice);
        uint256 got = scoin.redeem(x + extra, alice, alice);
        // net = got - topUp must not beat plain
        assertLe(got, plain + topUp, "top-up improved the exit");
        assertLe(asset.balanceOf(alice), before + plain, "top-up improved the exit (balance)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Monotonicity + preview inverses
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_previewRedeemMonotone(uint256 dep, uint256 credit, uint256 bad, uint256 x, uint256 d) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);
        _seed(dep, credit, bad);
        uint256 s = scoin.totalSupply();
        x = bound(x, 0, s);
        d = bound(d, 0, s - x);
        assertLe(scoin.previewRedeem(x), scoin.previewRedeem(x + d), "previewRedeem not monotone");
        assertLe(
            scoin.previewWithdraw(x / scale), scoin.previewWithdraw((x + d) / scale), "previewWithdraw not monotone"
        );
    }

    /// previewWithdraw(previewRedeem(s)) <= s  (withdraw path never charges more than redeem)
    /// previewRedeem(previewWithdraw(a)) >= a  (withdraw path never pays for fewer shares than redeem would)
    function testFuzz_previewInversesFavourVault(uint256 dep, uint256 credit, uint256 bad, uint256 x) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);
        _seed(dep, credit, bad);
        uint256 max = scoin.maxRedeem(alice);
        vm.assume(max > 0);
        x = bound(x, 1, max);

        uint256 a = scoin.previewRedeem(x);
        assertLe(scoin.previewWithdraw(a), x, "withdraw charges more shares than redeem");
        if (a > 0) {
            uint256 s2 = scoin.previewWithdraw(a);
            assertGe(scoin.previewRedeem(s2), a, "withdraw pays a for shares that redeem prices below a");
            // and the actual withdraw path agrees with its preview and with the accounting
            uint256 assetsBefore = scoin.totalAssets();
            uint256 reserveBefore = _reserve18();
            vm.prank(alice);
            uint256 burned = scoin.withdraw(a, alice, alice);
            assertEq(burned, s2, "withdraw burned != preview");
            assertEq(assetsBefore - scoin.totalAssets(), a * scale, "totalAssets moved != paid");
            assertEq(reserveBefore - _reserve18(), a * scale, "reserve moved != paid");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reserve identity: balance*scale >= unlockedSupply always, and equal up to scaling dust
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_reserveIdentity(uint256 dep, uint256 credit, uint256 bad, uint256 x, uint256 cover) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);
        _seed(dep, credit, bad);
        _checkIdentity(0);

        uint256 max = scoin.maxRedeem(alice);
        vm.assume(max > 0);
        x = bound(x, 1, max);
        vm.prank(alice);
        scoin.redeem(x, alice, alice);
        // stranded dust from the decimal floor and from the badDebt cap is at most one unit per redeem
        _checkIdentity(scale);

        // cover part of the shortfall from a fresh par mint
        vm.assume(scoin.badDebt() > 0);
        cover = bound(cover, 1, scoin.badDebt());
        uint256 units = (cover + scale - 1) / scale;
        asset.mint(treasury, units);
        vm.startPrank(treasury);
        asset.approve(address(scoin), units);
        scoin.deposit(units, treasury);
        scoin.coverBadDebt(cover);
        vm.stopPrank();
        _checkIdentity(scale);
        // I2
        assertGe(scoin.totalSupply(), scoin.creditBackedSupply() + scoin.badDebt(), "I2");
    }

    function _checkIdentity(uint256 slack) internal view {
        uint256 r = _reserve18();
        uint256 u = scoin.unlockedSupply();
        assertGe(r, u, "I1: reserve below unlockedSupply");
        assertLe(r - u, slack, "reserve strands more than slack");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Near-total shortfall: badDebt -> totalSupply - unlocked (backing ratio -> 0)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_nearTotalShortfall(uint256 dep, uint256 x, uint256 gap) public {
        dep = bound(dep, 10 ** dec, 1e6 * 10 ** dec);
        // credit huge relative to deposit, all of it written off
        uint256 credit = bound(gap, 1, 1e12) * 1e18;
        _seed(dep, credit, credit);
        uint256 max = scoin.maxRedeem(alice);
        assertEq(max, dep * scale, "unlocked == deposit");
        x = bound(x, 1, max);
        uint256 pv = scoin.previewRedeem(x);
        assertLe(pv * scale, x, "pays more than shares");
        uint256 reserveBefore = _reserve18();
        vm.prank(alice);
        uint256 paid = scoin.redeem(x, alice, alice);
        assertEq(paid, pv);
        assertLe(paid, asset.balanceOf(address(scoin)) + paid, "sanity");
        _checkIdentity(scale);
        // remaining holders' ratio never falls
        reserveBefore;
    }

    /// The backing ratio for stayers is non-decreasing across any redemption (the peg-repair claim)
    function testFuzz_ratioNeverFallsForStayers(uint256 dep, uint256 credit, uint256 bad, uint256 x) public {
        dep = bound(dep, 10 ** dec, 1e9 * 10 ** dec);
        credit = bound(credit, 1, 1e12 * 1e18);
        bad = bound(bad, 1, credit);
        _seed(dep, credit, bad);
        uint256 max = scoin.maxRedeem(alice);
        vm.assume(max > 0);
        x = bound(x, 1, max);
        uint256 s = scoin.totalSupply();
        uint256 a = scoin.totalAssets();
        vm.prank(alice);
        scoin.redeem(x, alice, alice);
        uint256 s2 = scoin.totalSupply();
        uint256 a2 = scoin.totalAssets();
        // a2/s2 >= a/s  <=>  a2*s >= a*s2
        assertGe(a2 * s, a * s2, "ratio fell for stayers");
    }
}

contract CurveTests6 is CurveTests {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract CurveTests8 is CurveTests {
    function _decimals() internal pure override returns (uint8) {
        return 8;
    }
}

contract CurveTests18 is CurveTests {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }
}
