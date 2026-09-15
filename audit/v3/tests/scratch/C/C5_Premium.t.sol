// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// P17 (removeTranche strands premium) and P18 (opt-in forfeiture / senior-idle redirect).
contract C5_Premium is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    Underwriter uw;
    MarketBundle b;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        uw = _deployUnderwriter();
        _admitDepositor(b.tranche0Addr, address(uw));
    }

    function _accrue(uint256 borrowDays) internal {
        vm.warp(block.timestamp + borrowDays * 1 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 20 * b.tranche0.vestingPeriod()); // let the tranche pot vest
    }

    // ───────────────────────────────────────────────────────────────────────────
    // P17: after removeTranche the underwriter still holds opted-in shares; premium keeps
    // accruing to it inside the tranche, but `report` refuses an unregistered tranche and
    // nothing else calls `claim`. Only re-adding the tranche recovers it.
    // ───────────────────────────────────────────────────────────────────────────
    function test_P17_removeTrancheStrandsSubsequentPremiumUntilReAdded() public {
        uw.addTranche(b.tranche0Addr);
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        _accrue(30);
        uw.removeTranche(b.tranche0Addr); // debt > 0 -> _report claims what has vested so far
        uint256 claimedAtRemoval = stablecoin.balanceOf(address(uw));
        assertGt(claimedAtRemoval, 0);
        assertTrue(b.tranche0.optedIn(address(uw)), "still opted in after removal");
        assertEq(b.tranche0.balanceOf(address(uw)), 1_000e18 - DEAD_SHARES, "still holding");

        // another month of premium lands on the underwriter's position in the tranche
        _accrue(30);
        uint256 stranded = b.tranche0.claimable(address(uw));
        console.log("claimed at removal:              ", claimedAtRemoval);
        console.log("claimable but unreachable after: ", stranded);
        assertGt(stranded, 0);

        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        uw.report(b.tranche0Addr);

        // deallocating banks it as `pending` inside the tranche; still nothing claims it
        uint256 freed = uw.deallocate(b.tranche0Addr, type(uint256).max);
        console.log("deallocated shares (locked part stays):", freed);
        assertEq(stablecoin.balanceOf(address(uw)), claimedAtRemoval, "nothing more reached the underwriter");
        assertGe(b.tranche0.claimable(address(uw)), stranded, "banked, not paid");

        // recovery: curator re-adds, keeper reports
        uw.addTranche(b.tranche0Addr);
        uw.report(b.tranche0Addr);
        assertGe(stablecoin.balanceOf(address(uw)), claimedAtRemoval + stranded - 1, "recovered by re-adding");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // P18a: a direct tranche depositor who does not optIn earns nothing; if NOBODY in the
    // senior tranche is opted in, the senior's weight (and every skipped junior's) is redirected
    // to cUSD stakers via fundCreditBacked. Documented only in BaseMarket._chargePremium NatSpec.
    // ───────────────────────────────────────────────────────────────────────────
    function test_P18_seniorWithNoOptInSendsAllUnderwriterPremiumToCUSD() public {
        // alice funds the senior WITHOUT opting in; bob funds the junior and opts in
        _fundVault(alice, 1_000e18);
        _admitDepositor(b.tranche0Addr, alice);
        vm.startPrank(alice);
        vault.setOperator(b.tranche0Addr, true);
        b.tranche0.deposit(1_000e18, alice);
        vm.stopPrank();
        assertEq(b.tranche0.stakedSupply(), 0, "nobody opted in on the senior");

        _fundTranche(b.tranche1Addr, bob, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        uint256 cusdPotBefore = stablecoin.remaining();
        vm.warp(block.timestamp + 30 days);
        (, uint256 uwPremiumDue) = b.market.premium();
        b.market.chargePremium();

        uint256 toSenior = stablecoin.balanceOf(b.tranche0Addr);
        uint256 toJunior = stablecoin.balanceOf(b.tranche1Addr);
        uint256 toCusd = stablecoin.remaining() - cusdPotBefore;
        console.log("underwriter premium charged:  ", uwPremiumDue);
        console.log("to senior (1000 capital):     ", toSenior);
        console.log("to junior (100 capital):      ", toJunior);
        console.log("to cUSD stakers (incl. liq.): ", toCusd);
        assertEq(toSenior, 0, "senior earns nothing");
        assertApproxEqRel(toJunior, uwPremiumDue * 5 / 100, 0.001e18, "junior gets its 5% weight");
        assertGe(toCusd, uwPremiumDue * 95 / 100, "the senior's 95% went to cUSD");

        // and alice, who backs 91% of the capital and takes first... no, last loss, has no claim
        assertEq(b.tranche0.claimable(alice), 0);
    }

    /// P18b: an underwriter depositor who forgets optIn on the Underwriter earns nothing from
    /// the Underwriter's pot; the underwriter itself IS opted in on every tranche it adds.
    function test_P18_underwriterDepositorWithoutOptInEarnsNothing() public {
        uw.addTranche(b.tranche0Addr);
        assertTrue(b.tranche0.optedIn(address(uw)), "addTranche opts the vault in");

        // alice opts in, carol does not
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundVault(carol, 500e18);
        _admitDepositor(address(uw), carol);
        vm.startPrank(carol);
        vault.setOperator(address(uw), true);
        uw.deposit(500e18, carol);
        vm.stopPrank();

        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        _accrue(30);
        uw.report(b.tranche0Addr);
        vm.warp(block.timestamp + 20 * uw.vestingPeriod());

        console.log("alice claimable:", uw.claimable(alice));
        console.log("carol claimable:", uw.claimable(carol));
        assertGt(uw.claimable(alice), 0);
        assertEq(uw.claimable(carol), 0, "same capital, same risk, no premium");
    }

    /// P18c: remove then re-add: optIn is idempotent, position stays opted in throughout, so no
    /// forfeiture on the re-add path.
    function test_P18_reAddDoesNotForfeit() public {
        uw.addTranche(b.tranche0Addr);
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        uw.removeTranche(b.tranche0Addr);
        assertTrue(b.tranche0.optedIn(address(uw)));
        uw.addTranche(b.tranche0Addr);
        assertTrue(b.tranche0.optedIn(address(uw)));
        assertEq(b.tranche0.stakedSupply(), 1_000e18 - DEAD_SHARES, "counted once");
    }
}
