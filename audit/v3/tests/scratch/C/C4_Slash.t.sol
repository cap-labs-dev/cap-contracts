// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { console } from "forge-std/console.sol";

/// Slash mechanics: full wipe, killed latch, dust-capital premium eligibility (I39), and the
/// underwriter's clean-up path on a dead tranche.
contract C4_Slash is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    Underwriter uw;
    MarketBundle b;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        uw = _deployUnderwriter();
        _admitDepositor(b.tranche0Addr, address(uw));
        uw.addTranche(b.tranche0Addr);
    }

    /// Speak as the market to aim a slash of an exact USD value at a tranche.
    function _marketSlash(Tranche t, uint256 value) internal returns (uint256 slashedValue) {
        vm.prank(t.market());
        slashedValue = t.slash(value, stranger);
    }

    /// Full wipe: shares survive, killed latches, convertToAssets is 0 for any holder, the
    /// underwriter marks the position to zero and can removeTranche and deallocate it away.
    function test_slash_fullWipe_underwriterCanCleanUp() public {
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        assertApproxEqAbs(uw.totalAssets(), 1_000e18, DEAD_SHARES);

        uint256 slashed = _marketSlash(b.tranche0, 1_000e18);
        assertEq(slashed, 1_000e18);
        assertEq(b.tranche0.totalAssets(), 0);
        assertTrue(b.tranche0.killed());
        assertEq(b.tranche0.totalSupply(), 1_000e18, "shares survive the wipe");
        assertEq(b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw))), 0, "worth nothing");
        assertEq(b.tranche0.maxDeposit(alice), 0, "killed blocks deposit");

        // the book is stale-high until marked (P4)
        assertApproxEqAbs(uw.totalAssets(), 1_000e18, DEAD_SHARES, "stale");
        uw.report(b.tranche0Addr);
        assertEq(uw.totalAssets(), 0, "marked to zero");

        // no debt: the shares are fully unlocked and redeem for 0 assets, burning them
        uint256 freed = uw.deallocate(b.tranche0Addr, type(uint256).max);
        assertEq(freed, 1_000e18 - DEAD_SHARES, "dead shares burned for nothing");
        assertEq(b.tranche0.balanceOf(address(uw)), 0);
        uw.removeTranche(b.tranche0Addr);
        assertFalse(vault.isOperator(address(uw), b.tranche0Addr));
    }

    /// With debt outstanding and the juniors not covering it, the wiped senior's shares cannot be
    /// redeemed (lockedShares is quoted against totalAssets + 1 = 1 and is astronomically large),
    /// but they are harmless: valued at 0 in the book, and removeTranche still works.
    function test_slash_fullWipe_withDebt_sharesStuckButWorthless() public {
        _fundTranche(b.tranche1Addr, bob, 500e18); // junior covers 500 of the 714 requirement
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);

        _marketSlash(b.tranche0, 1_000e18);
        assertEq(b.tranche0.totalAssets(), 0);
        console.log("lockedValue(tranche0):", b.market.lockedValue(b.tranche0Addr));
        console.log("unlockedSupply(t0):   ", b.tranche0.unlockedSupply());
        assertEq(b.tranche0.unlockedSupply(), 0, "senior shares locked although worthless");

        uw.report(b.tranche0Addr);
        assertEq(uw.totalDebt(), 0, "book carries them at zero");
        assertEq(uw.deallocate(b.tranche0Addr, type(uint256).max), 0, "nothing to pull, no revert");
        uw.removeTranche(b.tranche0Addr);
        assertEq(b.tranche0.balanceOf(address(uw)), 1_000e18 - DEAD_SHARES, "shares stay until the debt clears");

        // once the junior alone covers the debt again (repay 200), the dead shares can be burned
        _mintStable(defaultBorrower, 300e18);
        vm.prank(defaultBorrower);
        b.market.repay(200e18);
        assertEq(b.tranche0.unlockedSupply(), 1_000e18);
        uw.addTranche(b.tranche0Addr);
        assertEq(uw.deallocate(b.tranche0Addr, type(uint256).max), 1_000e18 - DEAD_SHARES);
    }

    /// A killed default tranche jams every underwriter deposit until the curator repoints it.
    function test_killedDefaultTrancheBlocksUnderwriterDeposits() public {
        uw.setDefaultTranche(b.tranche0Addr);
        _fundUnderwriter(address(uw), alice, 100e18);
        _marketSlash(b.tranche0, 99.5e18);
        assertTrue(b.tranche0.killed());
        _fundVault(bob, 10e18);
        _admitDepositor(address(uw), bob);
        vm.startPrank(bob);
        vault.setOperator(address(uw), true);
        vm.expectRevert();
        uw.deposit(10e18, bob);
        vm.stopPrank();
        uw.removeTranche(b.tranche0Addr); // clears the default
        vm.prank(bob);
        uw.deposit(10e18, bob);
    }

    /// I39: a killed tranche with dust capital and opted-in shares still takes its full weight.
    /// Senior killed to 0.5% of par (0.5e18 of 100e18) keeps 95% of the underwriter premium;
    /// the junior with 1000e18 of live capital gets 5%.
    function test_I39_killedDustSeniorTakesFullPremiumWeight() public {
        _fundTranche(b.tranche0Addr, alice, 100e18); // senior, opted in
        _fundTranche(b.tranche1Addr, bob, 1_000e18); // junior, opted in
        _marketSlash(b.tranche0, 99.5e18);
        assertTrue(b.tranche0.killed());
        assertEq(b.tranche0.totalAssets(), 0.5e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        uint256 toSenior = stablecoin.balanceOf(b.tranche0Addr);
        uint256 toJunior = stablecoin.balanceOf(b.tranche1Addr);
        console.log("senior (killed, 0.5 capital) premium:", toSenior);
        console.log("junior (1000 capital) premium:       ", toJunior);
        console.log("senior weight (ray):                 ", b.market.tranches()[0].weight);
        assertGt(toSenior, toJunior * 10, "the dead tranche out-earns the live one 19:1");
    }

    /// The eligibility floor is `totalCapital() > 0`, i.e. assets * price / 10^dec >= 1 wei USD.
    /// 1 wei of an 18-dec asset at $1 qualifies; at $0.50 it does not; 1 wei of a 6-dec asset
    /// at $1 is 1e12 wei USD.
    function test_I39_oneWeiEligibilityByDecimalsAndPrice() public {
        _fundTranche(b.tranche0Addr, alice, 100e18);
        _marketSlash(b.tranche0, 100e18 - 1);
        assertEq(b.tranche0.totalAssets(), 1);
        assertEq(b.tranche0.totalCapital(), 1, "1 wei at $1: capital 1 wei USD > 0 -> eligible");
        _setPrice(address(collateral), 0.5e18);
        assertEq(b.tranche0.totalCapital(), 0, "1 wei at $0.50: floors to 0 -> ineligible");
        _setPrice(address(collateral), 1e18);

        // 6-dec asset
        MockERC20 usdc6 = _newCollateral("USDC6", "USDC6", 6, 1e18);
        uint256[] memory w = new uint256[](3);
        w[0] = b.market.tranches()[0].weight;
        w[1] = b.market.tranches()[1].weight;
        w[2] = 0;
        vm.prank(defaultMarketOwner);
        address t6 = registry.createTranche(b.marketAddr, address(usdc6), w);
        _fundTranche(t6, address(usdc6), bob, 100e6);
        vm.prank(b.marketAddr);
        Tranche(t6).slash(100e18 - 1e12, stranger); // leave 1 wei (=1e12 wei USD)
        assertEq(Tranche(t6).totalAssets(), 1);
        assertEq(Tranche(t6).totalCapital(), 1e12, "1 wei of a 6-dec asset is 1e12 wei USD");
    }

    /// `slash` on a tranche whose feed died reverts InvalidPrice: the waterfall cannot skip it,
    /// so the whole liquidation reverts (P11, WS-D). Recorded here only as the coverage-side
    /// consequence: `totalCapital()` walks every tranche and reverts too, so health is unreadable.
    function test_slash_deadFeedBlocksWaterfallAndHealth() public {
        _fundTranche(b.tranche0Addr, alice, 100e18);
        _setStaleness(address(collateral), 1);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        b.market.totalCapital();
        vm.prank(b.marketAddr);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        b.tranche0.slash(1e18, stranger);
    }
}
