// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IPremiumVesting } from "../../../../../contracts/interfaces/IPremiumVesting.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 M-3 (C2 / R1_M3_JitPremium). Premium is attributed to whoever is
/// staked when it *arrives* (PremiumVesting._fund -> remainder, vests to `staked` from then,
/// PremiumVesting.sol:178-181, :232-246), not to whoever carried the exposure while it accrued.
/// FixedMarket still mints the whole term's premium at borrow (FixedMarket.sol:235-242).
/// API changes only: `redeem` -> `instantRedeem`, `maxRedeem` -> `maxInstantRedeem`.
contract R1_M3_JitPremium is CapDeployer {
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        _deployCap();
    }

    function _pct(uint256 part, uint256 whole) internal pure returns (uint256 bps) {
        bps = whole == 0 ? 0 : part * 10_000 / whole;
    }

    function _logShares(Tranche t, uint256 total, string memory label) internal {
        uint256 c = t.claimable(carol);
        uint256 a = t.claimable(alice);
        emit log_named_uint(label, 0);
        emit log_named_uint("  carol claimable (cUSD wei)", c);
        emit log_named_uint("  carol take, bps of total premium", _pct(c, total));
        emit log_named_uint("  alice claimable (cUSD wei)", a);
        emit log_named_uint("  alice take, bps of total premium", _pct(a, total));
    }

    /// (a) Underwriter.report sweeps premium the tranche accrued over the whole inter-report
    /// period and vests it to current Underwriter holders from then
    function test_JIT_underwriterReportWindow() public {
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
        vm.warp(block.timestamp + 30 days);
        uint256 accrued = b.tranche0.claimable(address(uw));
        emit log_named_uint("premium accrued to underwriter over 30d (cUSD)", accrued);

        // carol arrives one block before the keeper reports
        _fundUnderwriter(address(uw), carol, 1000e18);
        uw.report(address(b.tranche0));
        vm.warp(block.timestamp + 30 days);

        vm.prank(carol);
        uint256 carolGot = IPremiumVesting(address(uw)).claim(carol);
        vm.prank(alice);
        uint256 aliceGot = IPremiumVesting(address(uw)).claim(alice);
        emit log_named_uint("carol (0 days exposure) claimed", carolGot);
        emit log_named_uint("carol take, bps of swept premium", _pct(carolGot, accrued));
        emit log_named_uint("alice (30 days exposure) claimed", aliceGot);
        emit log_named_uint("carol maxInstantRedeem (underwriter shares)", uw.maxInstantRedeem(carol));
        assertEq(carolGot, 0, "a depositor absent during accrual should earn nothing from it");
    }

    /// (b) FixedMarket charges the whole term's premium up front, so a tranche depositor present
    /// at borrow collects a pro-rata share of the full-term premium and can then instant-redeem
    /// everything the buffer leaves unlocked.
    function test_JIT_fixedMarketUpfrontPremium() public {
        (address m, address t0,) = _createFixedMarket("F");
        FixedMarket market = FixedMarket(m);
        Tranche tranche0 = Tranche(t0);
        _setMarketSlopes(m);

        _fundTranche(t0, alice, 1000e18);
        _fundTranche(t0, carol, 1000e18); // front-runs the fixed borrow; optIn has no delay
        assertTrue(tranche0.optedIn(carol), "optIn is immediate");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18, 30 days);
        uint256 termPremium = stablecoin.balanceOf(t0);
        emit log_named_uint("30-day term premium minted to tranche at borrow (cUSD)", termPremium);

        uint256 t = block.timestamp;
        vm.warp(t + 6 hours);
        _logShares(tranche0, termPremium, "-- at +6h");
        vm.warp(t + 12 hours);
        _logShares(tranche0, termPremium, "-- at +12h");
        vm.warp(t + 24 hours);
        _logShares(tranche0, termPremium, "-- at +24h");

        vm.warp(t + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = IPremiumVesting(t0).claim(carol);
        emit log_named_uint("carol claimed after 6h", carolGot);
        emit log_named_uint("carol take after 6h, bps of term premium", _pct(carolGot, termPremium));

        uint256 carolShares = tranche0.balanceOf(carol);
        emit log_named_uint("carol shares", carolShares);
        emit log_named_uint("carol maxInstantRedeem after claim", tranche0.maxInstantRedeem(carol));
        vm.prank(carol);
        uint256 out = tranche0.instantRedeem(carolShares, carol, carol);
        emit log_named_uint("carol redeemed collateral", out);
        emit log_named_uint("hours of term remaining, carried by alice alone", 30 * 24 - 6);

        assertEq(carolGot, 0, "carol collected a share of a 30-day premium for 6 hours of exposure, then left");
    }

    /// Floating path: alice carries the loan for 30 days; carol deposits + opts in one block before
    /// `chargePremium` sweeps 30 days of premium into the tranche.
    function test_JIT_floatingChargePremium() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 30 days);
        _fundTranche(b.tranche0Addr, carol, 1000e18);
        uint256 before = stablecoin.balanceOf(b.tranche0Addr);
        b.market.chargePremium();
        uint256 swept = stablecoin.balanceOf(b.tranche0Addr) - before;
        emit log_named_uint("30d floating premium swept into tranche at chargePremium (cUSD)", swept);

        uint256 t = block.timestamp;
        vm.warp(t + 24 hours);
        _logShares(b.tranche0, swept, "-- at +24h");

        vm.prank(carol);
        uint256 carolGot = IPremiumVesting(b.tranche0Addr).claim(carol);
        emit log_named_uint("carol claimed at +24h", carolGot);
        emit log_named_uint("carol take, bps of swept premium", _pct(carolGot, swept));
        uint256 carolShares = b.tranche0.balanceOf(carol);
        vm.prank(carol);
        uint256 out = b.tranche0.instantRedeem(carolShares, carol, carol);
        emit log_named_uint("carol redeemed collateral", out);
        assertEq(carolGot, 0, "a depositor absent during accrual should earn nothing from it");
    }
}
