// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 M-4 (MED-RECOGNITION-LAG / R1_M4_RecognitionLag). The haircut curve
/// (Stablecoin._convertToAssets, :236-261) socialises only RECOGNISED `badDebt`; recognition is
/// GUARDIAN `writeOff` (-> `recognizeBadDebtInCredit`, :159-167) or GUARDIAN
/// `recognizeBadDebtInReserve` (:152-156). Nothing permissionless recognises; par exits continue.
/// API changes only: `redeem` -> `instantRedeem`, `previewRedeem` -> `convertToAssets`.
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

    function _crashToTenPercent() internal returns (uint256 shortfall) {
        uint256 S = stablecoin.totalSupply();
        uint256 D = market.totalDebt();
        uint256 target = S / 10;
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
        stablecoin.instantRedeem(shares, who, who);
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
        r.bPreview = stablecoin.convertToAssets(SAVER);
        r.assets = stablecoin.totalAssets();
        r.bad = stablecoin.badDebt();
        r.b = _redeemAll(saverB);
    }

    function _log(string memory tag, Res memory r) internal {
        emit log_string(tag);
        emit log_named_uint("  written off                 ", r.written);
        emit log_named_uint("  A received                  ", r.a);
        emit log_named_uint("  flat backing after A (1e18) ", r.flat);
        emit log_named_uint("  B convertToAssets           ", r.bPreview);
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
        assertEq(stablecoin.convertToAssets(SAVER), SAVER, "par while badDebt == 0");

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

        assertEq(L.a + L.assets, P.a + P.assets, "aggregate value conserved across branches");
        // desired property: exiting before recognition must not pay more than exiting after it
        assertLe(L.a, P.a, "a redeemer exits at par ahead of the guardian and shifts the loss to survivors");
    }

    /// Nothing but the guardian can recognise; no auto path; time alone does nothing.
    function test_noPermissionlessRecognition() public {
        _crashToTenPercent();
        vm.warp(block.timestamp + 30 days);
        vm.prank(saverA);
        stablecoin.instantRedeem(1e18, saverA, saverA);
        assertEq(stablecoin.badDebt(), 0, "no auto-recognition on redeem or on time");
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        market.writeOff();
        vm.prank(rando);
        vm.expectRevert();
        stablecoin.recognizeBadDebtInReserve(1);
        uint256 unlocked = stablecoin.unlockedSupply();
        uint256 before = cusdUnderlying.balanceOf(defaultBorrower);
        vm.prank(defaultBorrower);
        stablecoin.instantRedeem(unlocked, defaultBorrower, defaultBorrower);
        emit log_named_uint("borrower drained reserve at par", cusdUnderlying.balanceOf(defaultBorrower) - before);
        // desired property: an underwater market must not let its own borrower exit the reserve at par
        assertLt(
            cusdUnderlying.balanceOf(defaultBorrower) - before,
            unlocked,
            "defaulting borrower exits the whole reserve at par"
        );
    }

    /// `coverBadDebt` (public) only retires already-recognised badDebt; it cannot recognise.
    function test_coverBadDebtPublic_doesNotRecognise() public {
        uint256 shortfall = _crashToTenPercent();
        assertGt(shortfall, 0, "loan is underwater");
        assertEq(stablecoin.badDebt(), 0, "nothing recognised yet");

        address rando = makeAddr("rando");
        _depositStable(rando, 1_000e18);
        vm.prank(rando);
        vm.expectRevert(IStablecoin.NoBadDebt.selector);
        stablecoin.coverBadDebt(1_000e18);
        assertEq(stablecoin.convertToAssets(SAVER), SAVER, "still par");
        uint256 got = _redeemAll(saverA);
        emit log_named_uint("A exit before writeOff", got);
        assertLt(got, SAVER, "A still exits at par before writeOff");

        uint256 written = market.writeOff();
        assertEq(stablecoin.badDebt(), written, "recognised only via writeOff");
        vm.prank(rando);
        uint256 covered = stablecoin.coverBadDebt(1_000e18);
        assertEq(covered, 1_000e18);
        assertEq(stablecoin.badDebt(), written - covered, "only pays down recognised badDebt");
    }
}
