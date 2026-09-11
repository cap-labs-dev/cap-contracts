// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-C: premium is attributed to whoever holds shares when it *arrives* and vests over 6h from
/// then, not to whoever carried the exposure while it accrued. Two concrete windows:
///  (a) Underwriter.report (KEEPER cadence) sweeps premium the tranche accrued over the whole
///      inter-report period and vests it to current Underwriter holders over 6h;
///  (b) FixedMarket charges the whole term's premium up front, so a tranche depositor present at
///      borrow + 6h collects the full-term premium and can then instant-redeem everything the
///      buffer leaves unlocked.
contract C2_JitPremium is CapDeployer {
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        _deployCap();
    }

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
        vm.warp(block.timestamp + 6 hours + 1); // tranche-level vesting completes
        uint256 accrued = b.tranche0.claimable(address(uw));
        emit log_named_uint("premium accrued to underwriter over 30d (cUSD)", accrued);

        // carol arrives one block before the keeper reports
        _fundUnderwriter(address(uw), carol, 1000e18);
        uw.report(address(b.tranche0));
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(carol);
        uint256 carolGot = uw.claim();
        vm.prank(alice);
        uint256 aliceGot = uw.claim();
        emit log_named_uint("carol (0 days exposure) claimed", carolGot);
        emit log_named_uint("alice (30 days exposure) claimed", aliceGot);
        assertEq(carolGot, 0, "a depositor absent during accrual should earn nothing from it");
    }

    function test_JIT_fixedMarketUpfrontPremium() public {
        (address m, address t0,) = _createFixedMarket("F");
        FixedMarket market = FixedMarket(m);
        Tranche tranche0 = Tranche(t0);
        _setMarketSlopes(m);

        _fundTranche(t0, alice, 1000e18);
        // carol front-runs the fixed borrow
        _fundTranche(t0, carol, 1000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18, 30 days);
        uint256 termPremium = stablecoin.balanceOf(t0);
        emit log_named_uint("30-day term premium minted to tranche at borrow (cUSD)", termPremium);

        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(carol);
        uint256 carolGot = tranche0.claim(carol);
        emit log_named_uint("carol claimed after 6h", carolGot);

        // and leaves: the buffer leaves 2000 - 500/0.7 = 1285 shares unlocked, more than she holds
        uint256 carolShares = tranche0.balanceOf(carol);
        emit log_named_uint("carol shares", carolShares);
        emit log_named_uint("tranche instantUnlockedSupply", tranche0.instantUnlockedSupply());
        vm.prank(carol);
        uint256 out = tranche0.redeem(carolShares, carol, carol);
        emit log_named_uint("carol redeemed collateral", out);
        emit log_named_uint("hours of term remaining, carried by alice alone", 30 * 24 - 6);

        assertEq(carolGot, 0, "carol collected half a 30-day premium for 6 hours of exposure, then left");
    }
}
