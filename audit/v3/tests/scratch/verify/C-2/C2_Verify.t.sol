// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../../contracts/cap/Underwriter.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { console } from "forge-std/console.sol";

/// Independent verification of C-2, ENTRY leg. Written without the author's reasoning; only
/// the finding text and the code. Every number is re-derived from closed forms and checked
/// against the on-chain result to within a few wei of rounding.
contract C2_Verify is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
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

    /// 1000 in, all allocated via the default tranche, borrower at max, then a real liquidation.
    /// Returns L = tokens removed from the tranche by the slash.
    function _seedAndSlash(uint256 repay, uint256 price) internal returns (uint256 L) {
        uw.setDefaultTranche(b.tranche0Addr);
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);

        uint256 before = b.tranche0.totalAssets();
        _setPrice(address(collateral), price);
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, repay);
        L = before - b.tranche0.totalAssets();
    }

    function _live() internal view returns (uint256) {
        return vault.balanceOf(address(uw), address(collateral))
            + b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)) + uw.queuedShares(b.tranche0Addr));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        _admitDepositor(address(uw), who);
        _fundVault(who, amount);
        vm.startPrank(who);
        vault.setOperator(address(uw), true);
        shares = uw.deposit(amount, who);
        vm.stopPrank();
    }

    // ── (3) re-derive the numbers ───────────────────────────────────────────

    /// L = 102 USD / 0.55 = 185.4545 tokens; carol's post-deposit value = d(A-L+d)/(A+d) = 83.14;
    /// loss = dL/(A+d) = 16.86; fair shares = dS/(A-L) = 122.77. All match to within rounding.
    function test_V_entryNumbersRederived() public {
        uint256 L = _seedAndSlash(100e18, 0.55e18);
        uint256 A = uw.totalAssets(); // stale book
        uint256 S = uw.totalSupply();
        uint256 live = _live();
        assertEq(A, 1000e18 - 1000, "book is 1000 less the dead-share seed");
        assertEq(S, 1000e18 + 1000, "supply: 1000 plus the ~1000 wei bob was over-minted on the seed-dusted book");
        assertApproxEqAbs(L, uint256(102e18) * 1e18 / 0.55e18, 2, "L = 102 USD at 0.55");
        assertApproxEqAbs(live + L, A, 1e3, "live = book - L (tranche-share floor rounding only)");

        uint256 d = 100e18;
        uint256 shares = _depositAs(carol, d);
        // quoted on the stale book: d*(S+1)/(A+1) floor
        assertEq(shares, d * (S + 1) / (A + 1), "shares are the stale quote");

        uint256 value = uw.convertToAssets(shares);
        uint256 expectValue = d * (A - L + d) / (A + d);
        uint256 expectLoss = d * L / (A + d);
        uint256 fairShares = d * S / (A - L);
        console.log("L (tokens slashed)         :", L);
        console.log("carol shares (stale quote) :", shares);
        console.log("carol shares (live quote)  :", fairShares);
        console.log("carol value after deposit  :", value);
        console.log("closed form d(A-L+d)/(A+d) :", expectValue);
        console.log("carol loss                 :", d - value);
        console.log("closed form dL/(A+d)       :", expectLoss);
        assertApproxEqAbs(value, expectValue, 1e6, "value matches the closed form");
        assertApproxEqAbs(d - value, expectLoss, 1e6, "loss matches dL/(A+d)");
        assertApproxEqAbs(fairShares, 122767857142857142857, 1e6, "fair shares = 122.77");
        assertApproxEqAbs(value, 83140495867768595041, 1e6, "value = 83.14");
        // the book is fresh on return: the deposit itself marked
        assertEq(uw.totalAssets(), _live(), "book == live after the deposit");
        assertEq(uw.totalDebt(), b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw))));
    }

    // ── (2) is there a check that blocks the path? ──────────────────────────

    /// No permissionless way to refresh the book: every _mark caller is `restricted`.
    function test_V_noPermissionlessMark() public {
        _seedAndSlash(100e18, 0.55e18);
        uint256 stale = uw.totalAssets();
        assertGt(stale, _live());
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        uw.report(b.tranche0Addr);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        uw.allocate(b.tranche0Addr, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        uw.deallocate(b.tranche0Addr, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        uw.deallocateAsync(b.tranche0Addr, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        uw.finalizeDeallocateAsync(b.tranche0Addr, 1, 0);
        vm.stopPrank();
        assertEq(uw.totalAssets(), stale, "still stale");
    }

    /// The only on-chain guard in the entry path is the tranche kill switch: a slash below 1% of
    /// par makes Tranche.maxDeposit 0 and the underwriter deposit reverts instead of mispricing.
    /// That only covers a >99% loss, i.e. not the finding's scenario.
    function test_V_killSwitchOnlyBlocksCatastrophicSlash() public {
        // price 0.01 -> a 100 cUSD repay (+2% bonus) wants 10,200 tokens; capped at total 1000 -> tranche is emptied and killed
        _seedAndSlash(100e18, 0.01e18);
        assertTrue(b.tranche0.killed(), "tranche killed");
        _admitDepositor(address(uw), carol);
        _fundVault(carol, 100e18);
        vm.startPrank(carol);
        vault.setOperator(address(uw), true);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit inside _allocate
        uw.deposit(100e18, carol);
        vm.stopPrank();
    }

    // ── (4) bounds: the entry loss is NOT bounded by idle but IS bounded by L, and the
    //        same-tx refresh makes it a one-shot with a default tranche ────────

    /// idle == 0 throughout, so the exit leg's `idle * L / A` bound is zero, yet the entry loss
    /// is positive. As d grows the loss tends to L from below: it is bounded by L, not idle.
    function test_V_entryLossBoundedByLNotIdle() public {
        uint256 L = _seedAndSlash(100e18, 0.55e18);
        assertEq(vault.balanceOf(address(uw), address(collateral)), 0, "idle is zero");
        uint256 A = uw.totalAssets();
        uint256 d = 100_000e18; // a whale enters
        uint256 shares = _depositAs(carol, d);
        uint256 loss = d - uw.convertToAssets(shares);
        console.log("whale d          :", d);
        console.log("whale loss       :", loss);
        console.log("dL/(A+d)         :", d * L / (A + d));
        console.log("L                :", L);
        assertApproxEqAbs(loss, d * L / (A + d), 1e6, "loss = dL/(A+d)");
        assertLt(loss, L, "loss is strictly below L");
        assertGt(loss, L * 99 / 100, "...but approaches L for a large d");
    }

    /// With a default tranche the first deposit refreshes the book, so a second depositor in the
    /// same window is quoted live and loses nothing. The entry leg is a single-victim event.
    function test_V_secondDepositorIsQuotedLive() public {
        _seedAndSlash(100e18, 0.55e18);
        uint256 s1 = _depositAs(carol, 100e18);
        assertLt(uw.convertToAssets(s1), 100e18 - 1e15, "carol lost");
        uint256 s2 = _depositAs(dave, 100e18);
        assertApproxEqAbs(uw.convertToAssets(s2), 100e18, 1e3, "dave is whole");
    }

    /// Without a default tranche several depositors can be misquoted in one window, but the sum
    /// of their losses is still (sum d) * L / (A + sum d) < L.
    function test_V_multipleEntrantsWithoutDefaultTrancheSumBelowL() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        uint256 before = b.tranche0.totalAssets();
        _setPrice(address(collateral), 0.55e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, 100e18);
        uint256 L = before - b.tranche0.totalAssets();
        uint256 A = uw.totalAssets();

        uint256 s1 = _depositAs(carol, 100e18);
        uint256 s2 = _depositAs(dave, 300e18);
        assertEq(uw.totalAssets(), A + 400e18, "book still stale: no mark without a default tranche");
        uw.report(b.tranche0Addr);
        uint256 loss = 400e18 - uw.convertToAssets(s1) - uw.convertToAssets(s2);
        console.log("two entrants' summed loss:", loss);
        console.log("(sum d) L / (A + sum d)  :", 400e18 * L / (A + 400e18));
        assertApproxEqAbs(loss, 400e18 * L / (A + 400e18), 1e6);
        assertLt(loss, L);
    }

    /// `mint` has the same shape: previewMint on the stale book charges more assets than a live quote.
    function test_V_mintOvercharges() public {
        uint256 L = _seedAndSlash(100e18, 0.55e18);
        uint256 A = uw.totalAssets();
        uint256 S = uw.totalSupply();
        _admitDepositor(address(uw), carol);
        _fundVault(carol, 1_000e18);
        vm.startPrank(carol);
        vault.setOperator(address(uw), true);
        uint256 paid = uw.mint(100e18, carol);
        vm.stopPrank();
        uint256 fairAssets = 100e18 * (A - L) / S; // live price
        console.log("mint(100): paid        :", paid);
        console.log("mint(100): fair (live) :", fairAssets);
        console.log("mint(100): value now   :", uw.convertToAssets(100e18));
        assertGt(paid, fairAssets + 1e18, "charged well above live");
        assertLt(uw.convertToAssets(100e18), paid, "worth less than paid the moment mint returns");
    }
}
