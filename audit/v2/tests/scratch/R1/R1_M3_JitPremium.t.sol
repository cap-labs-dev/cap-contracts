// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IPremiumVesting } from "../../../../../contracts/interfaces/IPremiumVesting.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Round-2 port of round-1 C2 (M-3): premium is attributed to whoever is staked when it
/// *arrives* and vests from then, not to whoever carried the exposure while it accrued.
///
/// Port notes (API only; assertions identical in meaning to round 1):
///  - `Tranche.claim(recipient)` -> `IPremiumVesting(tranche).claim(recipient)` after `optIn()`
///    (`_fundTranche` deposits AND opts in)
///  - vesting is now exponential `1 - r^t` with a fixed 12 h constant (was linear over 6 h)
///  - `notifyPremium` gone; premium arrives from the market's `chargePremium` / fixed `borrow`
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

    /// @dev (a) Underwriter.report sweeps premium the tranche accrued over the whole inter-report
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

        // 30 days of exposure carried by alice alone
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 30 days); // tranche-level vesting (12 h constant) is fully done
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
        emit log_named_uint("carol maxRedeem (underwriter shares)", uw.maxRedeem(carol));
        assertEq(carolGot, 0, "a depositor absent during accrual should earn nothing from it");
    }

    /// @dev (b) FixedMarket charges the whole term's premium up front, so a tranche depositor present
    /// at borrow collects a pro-rata share of the full-term premium and can then instant-redeem
    /// everything the buffer leaves unlocked.
    function test_JIT_fixedMarketUpfrontPremium() public {
        (address m, address t0,) = _createFixedMarket("F");
        FixedMarket market = FixedMarket(m);
        Tranche tranche0 = Tranche(t0);
        _setMarketSlopes(m);

        _fundTranche(t0, alice, 1000e18);
        // carol front-runs the fixed borrow (deposit + optIn in the same block; optIn has no delay)
        _fundTranche(t0, carol, 1000e18);
        assertTrue(tranche0.optedIn(carol), "optIn is immediate");
        emit log_named_uint("carol maxRedeem right after optIn (shares)", tranche0.maxRedeem(carol));

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

        // claim at +6h as in round 1 (the round-1 vest completed at 6h; the round-2 vest is exponential)
        vm.warp(t + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = IPremiumVesting(t0).claim(carol);
        emit log_named_uint("carol claimed after 6h", carolGot);
        emit log_named_uint("carol take after 6h, bps of term premium", _pct(carolGot, termPremium));

        // and leaves: the buffer leaves 2000 - 500/0.7 = 1285 shares unlocked, more than she holds
        uint256 carolShares = tranche0.balanceOf(carol);
        emit log_named_uint("carol shares", carolShares);
        emit log_named_uint("carol maxRedeem after claim", tranche0.maxRedeem(carol));
        emit log_named_uint("tranche instantUnlockedSupply", tranche0.instantUnlockedSupply());
        vm.prank(carol);
        uint256 out = tranche0.redeem(carolShares, carol, carol);
        emit log_named_uint("carol redeemed collateral", out);
        emit log_named_uint("carol principal deposited", 1000e18);
        emit log_named_uint("hours of term remaining, carried by alice alone", 30 * 24 - 6);

        assertEq(carolGot, 0, "carol collected half a 30-day premium for 6 hours of exposure, then left");
    }

    /// @dev Round-2 addition, floating path: alice carries a floating loan for 30 days; carol
    /// deposits + opts in one block before `chargePremium` sweeps the 30 days of premium into the
    /// tranche, then measures her claimable share at +6h/+12h/+24h and whether she can leave.
    function test_JIT_floatingChargePremium() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 30 days);
        // carol arrives one block before the premium is charged
        _fundTranche(b.tranche0Addr, carol, 1000e18);
        uint256 before = stablecoin.balanceOf(b.tranche0Addr);
        b.market.chargePremium();
        uint256 swept = stablecoin.balanceOf(b.tranche0Addr) - before;
        emit log_named_uint("30d floating premium swept into tranche at chargePremium (cUSD)", swept);

        uint256 t = block.timestamp;
        vm.warp(t + 6 hours);
        _logShares(b.tranche0, swept, "-- at +6h");
        vm.warp(t + 12 hours);
        _logShares(b.tranche0, swept, "-- at +12h");
        vm.warp(t + 24 hours);
        _logShares(b.tranche0, swept, "-- at +24h");

        vm.prank(carol);
        uint256 carolGot = IPremiumVesting(b.tranche0Addr).claim(carol);
        emit log_named_uint("carol claimed at +24h", carolGot);
        emit log_named_uint("carol take, bps of swept premium", _pct(carolGot, swept));
        uint256 carolShares = b.tranche0.balanceOf(carol);
        emit log_named_uint("carol maxRedeem after claim", b.tranche0.maxRedeem(carol));
        vm.prank(carol);
        uint256 out = b.tranche0.redeem(carolShares, carol, carol);
        emit log_named_uint("carol redeemed collateral", out);
        assertEq(carolGot, 0, "a depositor absent during accrual should earn nothing from it");
    }
}
