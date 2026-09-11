// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Round-2 port of round-1 MED-RECOGNITION-LAG (M-4) PoC. Assertions identical to
/// audit/tests/scratch/verify/MED-RECOGNITION-LAG/Verify_RecognitionLag.t.sol; only the harness
/// API changed (`oracle.setPrice` -> `_setPrice`, which needs a price expressible in 8 feed decimals,
/// so the crash price is floored to a 1e10 multiple; the branch assertions use the realised
/// `unrecoverableDebt()` and are unaffected).
///   LAG    : unrecoverable slice exists, saver A redeems at par, THEN guardian writes off.
///   PROMPT : guardian writes off first, THEN saver A redeems on the curve.
contract R1_M4_RecognitionLag is CapDeployer {
    FloatingMarket market;
    address uw = makeAddr("uw");
    address saverA = makeAddr("saverA");
    address saverB = makeAddr("saverB");

    uint256 constant COLLATERAL = 160_000e18;
    uint256 constant SAVER = 10_000e18;

    function setUp() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("Floating");
        market = b.market;
        _fundTranche(b.tranche0Addr, uw, COLLATERAL);
        market.setFixedCreditLimit(type(uint256).max);
        _depositStable(saverA, SAVER);
        _depositStable(saverB, SAVER);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
    }

    /// @dev price the collateral so that unrecoverableDebt == ~10% of totalSupply
    function _crashToTenPercent() internal returns (uint256 shortfall) {
        uint256 S = stablecoin.totalSupply();
        uint256 D = market.totalDebt();
        uint256 target = S / 10;
        // unrecoverable = D - capital / 1.02  =>  capital = (D - target) * 1.02
        uint256 capital = (D - target) * (1e27 + irm.liquidationBonus()) / 1e27;
        uint256 price = capital * 1e18 / COLLATERAL;
        price = price / 1e10 * 1e10; // feed has 8 decimals
        _setPrice(address(collateral), price);
        shortfall = market.unrecoverableDebt();
    }

    function _flat() internal view returns (uint256) {
        return stablecoin.totalAssets() * 1e18 / stablecoin.totalSupply();
    }

    function _redeemAll(address who) internal returns (uint256 got) {
        uint256 shares = stablecoin.balanceOf(who);
        uint256 before = cusdUnderlying.balanceOf(who);
        vm.prank(who);
        stablecoin.redeem(shares, who, who);
        got = cusdUnderlying.balanceOf(who) - before;
    }

    struct Res {
        uint256 written;
        uint256 a;
        uint256 flat;
        uint256 bPreview;
        uint256 assets;
        uint256 bad;
        uint256 b;
    }

    function _branch(bool lag) internal returns (Res memory r) {
        if (lag) r.a = _redeemAll(saverA);
        r.written = market.writeOff();
        if (!lag) r.a = _redeemAll(saverA);
        r.flat = _flat();
        r.bPreview = stablecoin.previewRedeem(SAVER);
        r.assets = stablecoin.totalAssets();
        r.bad = stablecoin.badDebt();
        r.b = _redeemAll(saverB);
    }

    function _log(string memory tag, Res memory r) internal {
        emit log_string(tag);
        emit log_named_uint("  written off                 ", r.written);
        emit log_named_uint("  A received                  ", r.a);
        emit log_named_uint("  flat backing after A (1e18) ", r.flat);
        emit log_named_uint("  B previewRedeem             ", r.bPreview);
        emit log_named_uint("  B actually received         ", r.b);
        emit log_named_uint("  totalAssets after A         ", r.assets);
        emit log_named_uint("  badDebt after A             ", r.bad);
    }

    function test_lagVsPrompt_halfTheReserveExitsAtPar() public {
        uint256 shortfall = _crashToTenPercent();
        uint256 S0 = stablecoin.totalSupply();
        uint256 R0 = cusdUnderlying.balanceOf(address(stablecoin));
        emit log_named_uint("supply S0                     ", S0);
        emit log_named_uint("reserve R0 (unlockedSupply)   ", stablecoin.unlockedSupply());
        emit log_named_uint("unrecoverableDebt (~10% of S) ", shortfall);
        assertEq(stablecoin.badDebt(), 0, "not yet recognised");
        assertEq(stablecoin.unlockedSupply(), R0, "reserve identity holds pre-recognition");
        assertEq(stablecoin.previewRedeem(SAVER), SAVER, "par while badDebt == 0");

        uint256 snap = vm.snapshotState();
        Res memory L = _branch(true);
        assertEq(L.a, SAVER, "A paid par from the reserve");
        _log("LAG branch (A at par, then writeOff)", L);
        vm.revertToState(snap);
        Res memory P = _branch(false);
        _log("PROMPT branch (writeOff, then A on the curve)", P);
        assertEq(P.written, L.written, "same write-off amount either way");

        emit log_string("DELTAS (LAG - PROMPT)");
        emit log_named_int("  A gain from par exit        ", int256(L.a) - int256(P.a));
        emit log_named_int("  B loss (actual redeem)      ", int256(L.b) - int256(P.b));
        emit log_named_int("  B loss (flat backing, 1e18) ", int256(L.flat) - int256(P.flat));
        emit log_named_int("  A + totalAssets (LAG-PROMPT)", int256(L.a + L.assets) - int256(P.a + P.assets));

        assertGt(L.a, P.a, "A is better off exiting before recognition");
        assertLt(L.b, P.b, "B is worse off when A left at par");
        assertLt(L.flat, P.flat, "flat backing for survivors lower in LAG");
        assertEq(L.a + L.assets, P.a + P.assets, "aggregate value conserved across branches");
        assertApproxEqRel(L.flat, (S0 - SAVER - shortfall) * 1e18 / (S0 - SAVER), 1e12, "model formula");
    }

    /// @dev Angle (c): nothing but the guardian can recognise; no auto path; time alone does nothing.
    function test_noPermissionlessRecognition() public {
        _crashToTenPercent();
        vm.warp(block.timestamp + 30 days);
        vm.prank(saverA);
        stablecoin.redeem(1e18, saverA, saverA);
        assertEq(stablecoin.badDebt(), 0, "no auto-recognition on redeem or on time");
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        market.writeOff();
        uint256 unlocked = stablecoin.unlockedSupply();
        uint256 before = cusdUnderlying.balanceOf(defaultBorrower);
        vm.prank(defaultBorrower);
        stablecoin.redeem(unlocked, defaultBorrower, defaultBorrower);
        emit log_named_uint("borrower drained reserve at par", cusdUnderlying.balanceOf(defaultBorrower) - before);
        assertEq(
            cusdUnderlying.balanceOf(defaultBorrower) - before,
            unlocked,
            "defaulting borrower exits the whole reserve at par"
        );
    }

    /// @dev Angle (d): a write-off is permanent debt forgiveness.
    function test_writeOffIsPermanentForgiveness_transientDipLever() public {
        uint256 debt0 = market.totalDebt();
        uint256 shortfall = _crashToTenPercent();
        market.writeOff();
        _setPrice(address(collateral), 1e18);
        emit log_named_uint("debt before dip               ", debt0);
        emit log_named_uint("debt after dip+writeOff+recover", market.totalDebt());
        emit log_named_uint("borrower forgiven             ", debt0 - market.totalDebt());
        emit log_named_uint("badDebt still on cUSD holders ", stablecoin.badDebt());
        emit log_named_uint("healthiness now (ray)         ", market.healthiness());
        assertApproxEqAbs(debt0 - market.totalDebt(), shortfall, 2, "borrower's debt reduced by the written-off slice");
        assertEq(stablecoin.badDebt(), shortfall, "loss stays with cUSD holders after recovery");
        assertGt(market.healthiness(), 1e27, "market fully healthy: collateral untouched, nothing to liquidate");
    }

    /// @dev NEW (round 2): `coverBadDebt` is now public. It only retires *already recognised*
    /// badDebt by burning the caller's own cUSD; it cannot recognise a loss. So an unrecognised
    /// underwater loan still has badDebt == 0, coverBadDebt reverts NoBadDebt, and a redeemer still
    /// exits at par. After the guardian writeOff it pays badDebt down (supply and badDebt fall
    /// together; totalAssets unchanged) -- i.e. it is a voluntary donation path, not a recognition one.
    function test_coverBadDebtPublic_doesNotRecognise() public {
        uint256 shortfall = _crashToTenPercent();
        assertGt(shortfall, 0, "loan is underwater");
        assertEq(stablecoin.badDebt(), 0, "nothing recognised yet");

        address rando = makeAddr("rando");
        _depositStable(rando, 1_000e18);
        // anyone may call it, but with badDebt == 0 it has nothing to cover and reverts
        vm.prank(rando);
        vm.expectRevert(IStablecoin.NoBadDebt.selector);
        stablecoin.coverBadDebt(1_000e18);
        assertEq(stablecoin.badDebt(), 0, "coverBadDebt did not recognise anything");
        assertEq(stablecoin.previewRedeem(SAVER), SAVER, "still par");
        uint256 got = _redeemAll(saverA);
        assertEq(got, SAVER, "A still exits at par before writeOff");

        // only the guardian write-off recognises; then coverBadDebt pays it down
        uint256 written = market.writeOff();
        assertEq(stablecoin.badDebt(), written, "recognised only via writeOff");
        uint256 supplyBefore = stablecoin.totalSupply();
        uint256 assetsBefore = stablecoin.totalAssets();
        vm.prank(rando);
        uint256 covered = stablecoin.coverBadDebt(1_000e18);
        emit log_named_uint("written off by guardian      ", written);
        emit log_named_uint("covered by rando (own cUSD)  ", covered);
        assertEq(covered, 1_000e18);
        assertEq(stablecoin.badDebt(), written - covered, "only pays down recognised badDebt");
        assertEq(stablecoin.totalSupply(), supplyBefore - covered, "caller's shares burned");
        assertEq(stablecoin.totalAssets(), assetsBefore, "totalAssets unchanged: pure supply/badDebt reduction");
        assertEq(stablecoin.balanceOf(rando), 0);
    }
}
