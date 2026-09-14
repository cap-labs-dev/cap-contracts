// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// P4 (round-1 H-1 regression, both sides) on HEAD a843c1d.
///
/// `Underwriter.totalAssets() = idle + totalDebt` (Underwriter.sol:243-245) where `totalDebt` is a
/// cache written only by `_mark` (allocate / deallocate / deallocateAsync / finalize / report).
/// `Tranche.totalAssets()` (Tranche.sol:103-105) moves live on `slash`. Between a slash and the
/// next `_mark` the underwriter's share price is stale-HIGH.
///
///   exit : any share holder `instantRedeem`s at the stale price, paid from idle; the loss is left
///          entirely with whoever stays.
///   entry: `deposit` computes shares via `previewDeposit` on the stale book BEFORE `_transferIn`
///          allocates and `_mark`s (OZ ERC4626Upgradeable.deposit:205-215 -> _deposit:273-285),
///          so the new depositor is minted too few shares in the SAME transaction that refreshes
///          the book.
///
/// Both tests assert the fair outcome and FAIL on current code.
contract C2_StaleMark is CapDeployer {
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
        uw.addTranche(b.tranche0Addr);
    }

    /// Slash tranche0 through a real liquidation: price 1.00 -> 0.55, LIQUIDATOR repays `repay` cUSD.
    function _liquidateFor(uint256 repay) internal returns (uint256 tokensSlashed) {
        tokensSlashed = _liquidateFor(repay, 0.55e18);
    }

    function _liquidateFor(uint256 repay, uint256 price) internal returns (uint256 tokensSlashed) {
        uint256 before = b.tranche0.totalAssets();
        _setPrice(address(collateral), price);
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, repay);
        tokensSlashed = before - b.tranche0.totalAssets();
    }

    // ───────────────────────────────────────────────────────────────────────────
    // EXIT: instantRedeem after a slash, before any _mark
    // ───────────────────────────────────────────────────────────────────────────
    function test_P4_exitAtStaleMarkAfterSlash() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(b.tranche0Addr, 500e18); // 500 allocated, 500 idle
        assertEq(vault.balanceOf(address(uw), address(collateral)), 500e18);

        // borrow the maximum: creditLimit = activeCapital * ltv = 500 * 0.5 = 250
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 250e18);

        uint256 slashedTokens = _liquidateFor(100e18);
        uint256 stale = uw.totalAssets();
        uint256 live = vault.balanceOf(address(uw), address(collateral))
            + b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)));

        uint256 aliceShares = uw.balanceOf(alice);
        uint256 supply = uw.totalSupply();
        uint256 aliceFair = aliceShares * live / supply;

        vm.prank(alice);
        uint256 alicePaid = uw.instantRedeem(aliceShares, alice, alice);

        // the keeper eventually marks; bob is left holding the whole slash
        uw.report(b.tranche0Addr);
        uint256 bobValue = uw.convertToAssets(uw.balanceOf(bob));
        uint256 bobFair = uw.balanceOf(bob) * live / supply;

        console.log("tokens slashed from tranche0:      ", slashedTokens);
        console.log("underwriter totalAssets (stale):   ", stale);
        console.log("underwriter live valuation:        ", live);
        console.log("alice fair:                        ", aliceFair);
        console.log("alice paid:                        ", alicePaid);
        console.log("alice over-paid:                   ", alicePaid - aliceFair);
        console.log("bob fair:                          ", bobFair);
        console.log("bob after report:                  ", bobValue);
        console.log("bob loss transferred to alice:     ", bobFair - bobValue);

        assertLe(alicePaid, aliceFair + 1, "exiting holder must not be paid above the live share price");
    }

    /// The exit needs no role: a transferee that was never admitted takes the stale price.
    function test_P4_exitNeedsNoRole() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(b.tranche0Addr, 500e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 250e18);
        _liquidateFor(100e18);

        address outsider = makeAddr("outsider");
        assertFalse(_mayDeposit(address(uw), outsider));
        uint256 shares = uw.balanceOf(alice);
        vm.prank(alice);
        uw.transfer(outsider, shares);

        uint256 live = vault.balanceOf(address(uw), address(collateral))
            + b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)));
        uint256 fair = shares * live / uw.totalSupply();
        vm.prank(outsider);
        uint256 paid = uw.instantRedeem(shares, outsider, outsider);
        console.log("outsider fair:", fair);
        console.log("outsider paid:", paid);
        assertLe(paid, fair + 1, "unadmitted transferee must not be paid above the live share price");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // ENTRY: deposit prices on the stale book, then _transferIn -> _allocate -> _mark refreshes it
    // in the same transaction. The depositor's shares are worth less than what they paid the
    // moment the call returns.
    // ───────────────────────────────────────────────────────────────────────────
    function test_P4_entryOverpaysInSameTx() public {
        uw.setDefaultTranche(b.tranche0Addr); // every deposit is allocated straight through
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        assertEq(vault.balanceOf(address(uw), address(collateral)), 0, "nothing idle");

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18); // activeCapital 1000 * ltv 0.5
        uint256 slashed = _liquidateFor(100e18);

        uint256 stale = uw.totalAssets();
        uint256 live = b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)));
        assertGt(stale, live, "book is stale-high after the slash");

        // carol, an admitted depositor, deposits 100 in the window
        _admitDepositor(address(uw), carol);
        _fundVault(carol, 100e18);
        vm.startPrank(carol);
        vault.setOperator(address(uw), true);
        uint256 shares = uw.deposit(100e18, carol);
        vm.stopPrank();

        // the deposit itself re-marked the book (allocate -> _mark), so this is the live price
        uint256 carolValue = uw.convertToAssets(shares);
        uint256 fairShares = 100e18 * (uw.totalSupply() - shares) / live; // what a live quote would have minted

        console.log("tokens slashed from tranche0:       ", slashed);
        console.log("book before carol (stale):          ", stale);
        console.log("live position before carol:         ", live);
        console.log("carol deposited:                     100000000000000000000");
        console.log("carol shares minted (stale quote):  ", shares);
        console.log("carol shares at a live quote:       ", fairShares);
        console.log("carol value right after deposit:    ", carolValue);
        console.log("carol immediate loss:               ", 100e18 - carolValue);
        console.log("book after carol (fresh):           ", uw.totalAssets());

        assertGe(carolValue + 1, 100e18, "a depositor must not lose value inside the deposit that refreshes the book");
    }

    /// Without a default tranche the deposit does not re-mark; the loss lands at the next report.
    function test_P4_entryOverpaysWithoutDefaultTranche() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        _liquidateFor(100e18);

        _admitDepositor(address(uw), carol);
        _fundVault(carol, 100e18);
        vm.startPrank(carol);
        vault.setOperator(address(uw), true);
        uint256 shares = uw.deposit(100e18, carol);
        vm.stopPrank();
        assertEq(uw.convertToAssets(shares), 100e18 - 1, "quoted at par on the stale book");

        uw.report(b.tranche0Addr);
        uint256 carolValue = uw.convertToAssets(shares);
        console.log("carol value after the keeper marks:", carolValue);
        assertGe(carolValue + 1, 100e18, "a depositor must not overpay against a stale book");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // I37 direction: the cached book is never BELOW the live valuation absent a gratuitous
    // ERC-6909 donation to the tranche. Deposits/withdrawals in the tranche keep the per-share
    // price; slash lowers it; premium is cUSD and never enters totalAssets.
    // ───────────────────────────────────────────────────────────────────────────
    function test_I37_bookNeverBelowLiveThroughNormalActivity() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(b.tranche0Addr, 600e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        // premium accrues and is claimed: totalAssets unchanged by the cUSD leg
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 1 days);
        uint256 beforeReport = uw.totalAssets();
        uw.report(b.tranche0Addr);
        assertEq(uw.totalAssets(), beforeReport, "premium is cUSD, not tranche assets");
        _assertBookGeLive();

        // a third-party direct depositor joins and leaves the tranche: per-share unchanged
        _fundTranche(b.tranche0Addr, carol, 300e18);
        _assertBookGeLive();
        vm.startPrank(carol);
        b.tranche0.instantRedeem(b.tranche0.maxInstantRedeem(carol), carol, carol);
        vm.stopPrank();
        _assertBookGeLive();

        // slash: book stays above live until marked
        _liquidateFor(50e18, 0.3e18);
        _assertBookGeLive();
        uw.report(b.tranche0Addr);
        _assertBookGeLive();
        assertEq(uw.totalDebt(), b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw))), "equality after report");
    }

    /// The one way the book goes stale-LOW: anyone can donate ERC-6909 balance to a tranche.
    function test_I37_donationIsTheOnlyStaleLowPath() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        uw.allocate(b.tranche0Addr, 500e18);
        _fundVault(carol, 100e18);
        vm.prank(carol);
        vault.transfer(b.tranche0Addr, address(collateral), 100e18); // gift
        uint256 live = b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)));
        console.log("book:", uw.totalDebt());
        console.log("live:", live);
        assertLt(uw.totalDebt(), live, "gift makes the book stale-low (gain, not loss, for holders)");
    }

    function _assertBookGeLive() internal view {
        uint256 live = vault.balanceOf(address(uw), address(collateral))
            + b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)) + uw.queuedShares(b.tranche0Addr));
        assertGe(uw.totalAssets(), live, "I37: book >= live");
    }
}
