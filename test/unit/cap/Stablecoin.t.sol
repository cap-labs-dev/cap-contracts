// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { IStablecoin } from "../../../contracts/interfaces/IStablecoin.sol";
import { CapRoles } from "../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract StablecoinTest is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal asset;
    MockIRM internal irm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();

        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize, (address(accessManager), address(asset), "Cap USD", "cUSD", "", address(irm))
                )
            )
        );

        asset.mint(alice, 1_000e18);
        vm.prank(alice);
        asset.approve(address(scoin), type(uint256).max);

        // covering a shortfall is a governor action, matching the production wiring
        _grantRoleForTarget(CapRoles.GOVERNOR, treasury, address(scoin), _selectors(Stablecoin.coverBadDebt.selector));
    }

    /// @dev Bad debt only ever arises from a market writing off credit it minted, so the credit
    /// must exist before it can be written off. Mint it to a sink first to reach that state.
    function _writeOffCredit(uint256 amount) internal {
        scoin.mintCreditBacked(makeAddr("defaultedBorrower"), amount);
        scoin.recognizeBadDebt(amount);
    }

    function test_decimalsIs18() public view {
        assertEq(scoin.decimals(), 18);
    }

    function test_mintCreditBacked_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.mintCreditBacked(alice, 1e18);
    }

    function test_mintCreditBacked_increasesSupplyAndCreditBacked() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.balanceOf(bob), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
        assertEq(scoin.creditBackedSupply(), 100e18);
        assertEq(irm.updateCalls(), 1);
        assertEq(scoin.utilizationRate(), RAY);
    }

    function test_burnCreditBacked_decreases() public {
        scoin.mintCreditBacked(bob, 100e18);
        scoin.burnCreditBacked(bob, 40e18);
        assertEq(scoin.balanceOf(bob), 60e18);
        assertEq(scoin.totalSupply(), 60e18);
        assertEq(scoin.creditBackedSupply(), 60e18);
    }

    function test_unlockedSupply_excludesCreditBacked() public {
        vm.prank(alice);
        scoin.deposit(200e18, alice);
        scoin.mintCreditBacked(bob, 50e18);

        assertEq(scoin.totalSupply(), 250e18);
        assertEq(scoin.unlockedSupply(), 200e18);
    }

    function test_utilizationRate_partial() public {
        vm.prank(alice);
        scoin.deposit(300e18, alice);
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.utilizationRate(), 0.25e27);
    }

    function test_recognizeBadDebt_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.recognizeBadDebt(1e18);
    }

    function test_badDebt_reducesTotalAssets() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.totalAssets(), 100e18);
        scoin.recognizeBadDebt(30e18);
        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.totalAssets(), 70e18);
    }

    // ── the previews round at whatever scale the underlying uses ──────────────

    /// @dev Deploy against an underlying of a given width, so the preview arithmetic can be
    /// exercised at the six decimals real USDC carries. The rest of the suite runs on an
    /// eighteen-decimal mock, where both directions divide exactly and nothing can round at all,
    /// which is precisely why this went unnoticed.
    function _stablecoinOn(uint8 assetDecimals) internal returns (Stablecoin deployed) {
        MockERC20 underlying = new MockERC20("Scaled", "SCL", assetDecimals);
        deployed = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(underlying), "Cap USD", "cUSD", "", address(irm))
                )
            )
        );
    }

    /// @dev ERC-4626 puts the rounding on the quoting side in the vault's favour, and truncating
    /// instead hands out shares for nothing: against six decimals every share count below 1e12
    /// divides to zero assets owed. The sums are dust, but the reserve identity the redemption
    /// gate rests on should not be standing on a rounding direction.
    function test_previewMint_roundsUpAgainstASixDecimalUnderlying() public {
        Stablecoin usdc = _stablecoinOn(6);

        assertEq(usdc.previewMint(1), 1, "a single wei of cUSD still costs a base unit");
        assertEq(usdc.previewMint(1e12 - 1), 1, "and so does anything short of a whole one");
        assertEq(usdc.previewMint(1e12), 1, "which is what a whole one costs exactly");
        assertEq(usdc.previewMint(1e12 + 1), 2, "a wei over rounds on to the next");
        assertEq(usdc.previewMint(1e18), 1e6, "exact multiples are untouched");
    }

    /// @dev The deposit side keeps its floor, and at any width the vault accepts the division is
    /// exact anyway, so the asymmetry costs a depositor nothing.
    function test_previewDeposit_isExactAtSixDecimals() public {
        Stablecoin usdc = _stablecoinOn(6);

        assertEq(usdc.previewDeposit(1), 1e12, "one base unit buys a whole scaled share");
        assertEq(usdc.previewDeposit(1e6), 1e18, "and a dollar buys a dollar");
    }

    /// @dev Wider than the share the losing direction flips to the deposit side, where rounding up
    /// is not available: the assets have already been pulled by then, so anything too small to
    /// mint a share would simply be donated. Refused at initialize rather than carried.
    function test_initialize_rejectsAnUnderlyingWiderThanTheShare() public {
        MockERC20 wide = new MockERC20("Wide", "WIDE", 19);
        address impl = address(new Stablecoin());

        vm.expectRevert(IStablecoin.UnsupportedDecimals.selector);
        _deployProxy(
            impl,
            abi.encodeCall(
                Stablecoin.initialize, (address(accessManager), address(wide), "Cap USD", "cUSD", "", address(irm))
            )
        );
    }

    function test_deposit_oneToOne() public {
        vm.prank(alice);
        uint256 shares = scoin.deposit(100e18, alice);
        assertEq(shares, 100e18);
        assertEq(scoin.balanceOf(alice), 100e18);
        assertEq(asset.balanceOf(address(scoin)), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
    }

    function test_preview_oneToOne_18decimals() public view {
        assertEq(scoin.previewDeposit(123e18), 123e18);
        assertEq(scoin.previewMint(123e18), 123e18);
    }

    function test_maxRedeem_fullWhenLiquid() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        assertEq(scoin.maxRedeem(alice), 100e18);
    }

    function test_utilizationRate_zeroSupply_isZero() public view {
        assertEq(scoin.totalSupply(), 0);
        assertEq(scoin.utilizationRate(), 0);
    }

    /// Supply 120e18 against 100e18 of backing. Redeeming 50e18 leaves 70e18 of supply, which
    /// retains 70 * 120 * 100 / (120 * 100 + 70 * 20) = 62.6865... of the backing.
    function test_previewRedeem_withBadDebt_sharesAboveBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);

        assertApproxEqAbs(scoin.previewRedeem(50e18), 37.313432835820895522e18, 2, "priced on the shortfall curve");
    }

    /// Holding less than the shortfall no longer zeroes the redeemer out. Supply 160e18 against
    /// 100e18: redeeming 40e18 leaves 120e18, retaining 120 * 160 * 100 / (160 * 100 + 120 * 60)
    /// = 82.7586... of the backing, so the payout is the 17.2413... left over.
    function test_previewRedeem_withBadDebt_sharesBelowBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(60e18);

        assertApproxEqAbs(scoin.previewRedeem(40e18), 17.241379310344827586e18, 2, "paid something, not zero");
    }

    /// Redeeming the entire supply pays out exactly the reserve and no more, so the curve can
    /// never promise assets that are not there.
    function test_previewRedeem_wholeSupplyPaysExactlyTheBacking() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebt(100e18);

        assertEq(scoin.previewRedeem(scoin.totalSupply()), scoin.totalAssets(), "pays the whole reserve");
    }

    /// The old conversion paid early redeemers more than their share and let a single large
    /// redemption clear the whole shortfall while absorbing only a fraction of it. No redemption
    /// may now take out more than it reduces totalAssets by.
    function test_redeem_neverPaysMoreThanItReducesTotalAssets() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebt(100e18);

        uint256 assetsBefore = scoin.totalAssets();
        uint256 heldBefore = asset.balanceOf(address(scoin));

        vm.prank(alice);
        uint256 paid = scoin.redeem(1_000e18, alice, alice);

        // the 500e18 left behind retains 500 * 1500 * 1400 / (1500 * 1400 + 500 * 100) of the
        // backing, so alice takes the 911.62... that leaves over and absorbs the 88.37... gap
        assertApproxEqAbs(paid, 911.627906976744186046e18, 2, "priced on the shortfall curve");
        assertEq(assetsBefore - scoin.totalAssets(), paid, "totalAssets falls by exactly what was paid");
        assertEq(heldBefore - asset.balanceOf(address(scoin)), paid, "and so does the reserve");
        assertApproxEqAbs(scoin.badDebt(), 100e18 - (1_000e18 - paid), 2, "absorbs exactly what it left behind");
    }

    /// @dev The property the shortfall curve rests on, and the reason chopping a redemption up
    /// cannot beat taking it in one call: `badDebt / (totalSupply * totalAssets)` is conserved by a
    /// redemption. Since what a redemption retains is `remaining / (1 + k * remaining)` for that
    /// same `k`, the payout depends only on where the supply ends up and not on the route taken.
    ///
    /// What would break it is charging the marginal price — the backing ratio squared — on a whole
    /// redemption, since each slice lifts the ratio for the next and a sliced exit would harvest
    /// its own repair. The curve is that process integrated and charged upfront, which is what
    /// collapses the difference between one call and twenty.
    function testFuzz_slicingARedemptionCannotBeatTakingItWhole(uint8 slices) public {
        slices = uint8(bound(slices, 2, 20));

        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebt(100e18);

        uint256 k = _shortfallInvariant();
        uint256 whole = scoin.previewRedeem(600e18);

        // the same 600e18 exit, taken a slice at a time and re-priced against the state each
        // slice leaves behind
        uint256 taken;
        uint256 each = 600e18 / slices;
        for (uint256 i; i < slices; ++i) {
            uint256 shares = i + 1 == slices ? 600e18 - each * (slices - 1) : each;
            vm.prank(alice);
            taken += scoin.redeem(shares, alice, alice);
            assertApproxEqRel(_shortfallInvariant(), k, 1e6, "the invariant survives every slice");
        }

        assertApproxEqRel(taken, whole, 1e6, "and slicing pays no more than the single call");
    }

    /// @dev `badDebt * 1e36 / (totalSupply * totalAssets)`, scaled so the ratio is comparable
    /// across states without losing it to integer division
    function _shortfallInvariant() internal view returns (uint256 k) {
        k = Math.mulDiv(scoin.badDebt(), 1e36, scoin.totalSupply() * scoin.totalAssets());
    }

    /// previewWithdraw must be the inverse of previewRedeem above the shortfall.
    function test_previewWithdraw_isInverseOfPreviewRedeem() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);

        uint256 assets = scoin.previewRedeem(50e18);
        assertEq(scoin.previewWithdraw(assets), 50e18, "round trips exactly");
    }

    /// Minting stays at par while bad debt is outstanding. This is what caps the cost of acquiring
    /// cUSD at a dollar, so a liquidator can never conjure discounted cUSD and burn it against
    /// debt at face value to collect collateral the underwriters never charged them for.
    function test_previewDeposit_staysAtParWithBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(50e18);

        // half the supply is unbacked, but a dollar still buys exactly one cUSD
        assertEq(scoin.previewDeposit(100e18), 100e18, "minting is still one for one");
        assertEq(scoin.previewMint(100e18), 100e18, "minting is still one for one");
    }

    function test_previewWithdraw_withBadDebt_bothBranches() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);

        uint256 below = scoin.previewWithdraw(10e18);
        uint256 above = scoin.previewWithdraw(50e18);
        assertGt(below, 0);
        assertGt(above, below);
    }

    function test_instantRedeem_absorbsBadDebt_whenSharesExceedDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);
        uint256 irmBefore = irm.updateCalls();
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        // 120e18 supply against 100e18 of backing, redeeming 50e18; see previewRedeem above
        vm.prank(alice);
        uint256 assets = scoin.redeem(50e18, alice, alice);

        assertApproxEqAbs(assets, 37.313432835820895522e18, 2, "priced on the shortfall curve");
        assertApproxEqAbs(scoin.badDebt(), 20e18 - (50e18 - assets), 2, "absorbs what it left behind");
        // 100e18 deposited plus the 20e18 of written off credit, less the 50e18 redeemed
        assertEq(scoin.totalSupply(), 70e18);
        assertEq(asset.balanceOf(alice) - aliceAssetsBefore, assets);
        assertEq(irm.updateCalls(), irmBefore + 1);
    }

    /// A redeemer smaller than the outstanding shortfall must still be paid. Under the old model
    /// they received nothing at all, which punished small holders for the size of the loss.
    function test_instantRedeem_absorbsBadDebt_partial() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(60e18);

        // 160e18 supply against 100e18 of backing, redeeming 40e18; see previewRedeem above
        vm.prank(alice);
        uint256 assets = scoin.redeem(40e18, alice, alice);

        assertApproxEqAbs(assets, 17.241379310344827586e18, 2, "paid despite being smaller than the shortfall");
        assertEq(scoin.badDebt(), 60e18 - (40e18 - assets), "absorbs what it left behind");
        // 100e18 deposited plus the 60e18 of written off credit, less the 40e18 redeemed
        assertEq(scoin.totalSupply(), 120e18);
    }

    /// Small holders must not be zeroed out, and the rate must be near enough linear for them that
    /// holding less is not itself a penalty.
    function test_redeem_smallHoldersArePaidProportionally() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        _writeOffCredit(200e18);

        uint256 small = scoin.previewRedeem(1e18);
        assertGt(small, 0, "nobody is zeroed out");
        assertApproxEqRel(scoin.previewRedeem(10e18), small * 10, 0.01e18, "10x holder gets 10x");
    }

    /// Splitting a redemption must not beat doing it in one go. Pricing off the instantaneous
    /// ratio would fail this, because each redemption lifts the ratio for the next one and a
    /// redeemer could harvest their own repair a slice at a time.
    function testFuzz_redeem_splittingGainsNothing(uint256 written, uint256 each, uint256 chunks) public {
        written = bound(written, 1e18, 500e18);
        chunks = bound(chunks, 2, 20);

        uint256 snapshot = vm.snapshotState();
        _seedWrittenOffPool(written);
        uint256 maxShares = scoin.maxRedeem(alice);
        vm.revertToState(snapshot);

        // both legs redeem exactly the same total, so the comparison is like for like
        each = bound(each, 1e15, maxShares / chunks);
        uint256 total = each * chunks;

        _seedWrittenOffPool(written);
        vm.prank(alice);
        uint256 atOnce = scoin.redeem(total, alice, alice);
        vm.revertToState(snapshot);

        _seedWrittenOffPool(written);
        uint256 split;
        for (uint256 i; i < chunks; ++i) {
            vm.prank(alice);
            split += scoin.redeem(each, alice, alice);
        }

        assertApproxEqRel(split, atOnce, 0.00001e18, "splitting matches doing it in one go");
        assertLe(split, atOnce + chunks, "and never beats it by more than rounding dust");
    }

    function _seedWrittenOffPool(uint256 written) internal {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        _writeOffCredit(written);
    }

    /// Redeeming below the pool's own ratio is what repairs the peg: the redeemer takes less than
    /// their share of the backing and the difference lifts the ratio for everyone who stays.
    function test_redeem_belowRatio_restoresThePegForRemainingHolders() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        _writeOffCredit(200e18);

        uint256 ratioBefore = scoin.totalAssets() * 1e27 / scoin.totalSupply();
        uint256 shares = 300e18;

        // the redeemer is paid strictly less than their pro-rata share of the backing
        uint256 assets = scoin.previewRedeem(shares);
        assertLt(assets, shares * ratioBefore / 1e27, "priced below the pool ratio");

        vm.prank(alice);
        scoin.redeem(shares, alice, alice);

        uint256 ratioAfter = scoin.totalAssets() * 1e27 / scoin.totalSupply();
        assertGt(ratioAfter, ratioBefore, "the peg moves back toward par");
    }

    /// Whatever the payout, totalAssets must fall by exactly that amount, so no part of the loss
    /// is ever erased from the accounting or double counted.
    function testFuzz_redeem_totalAssetsFallsByExactlyThePayout(uint256 deposited, uint256 written, uint256 shares)
        public
    {
        deposited = bound(deposited, 1e18, 1_000e18);
        written = bound(written, 1e18, 1_000e18);
        vm.prank(alice);
        scoin.deposit(deposited, alice);
        _writeOffCredit(written);

        shares = bound(shares, 1, scoin.maxRedeem(alice));
        uint256 assetsBefore = scoin.totalAssets();
        uint256 heldBefore = asset.balanceOf(address(scoin));

        vm.prank(alice);
        uint256 paid = scoin.redeem(shares, alice, alice);

        assertEq(assetsBefore - scoin.totalAssets(), paid, "totalAssets tracks the payout exactly");
        assertEq(heldBefore - asset.balanceOf(address(scoin)), paid, "and so does the reserve");
        assertLe(paid, shares, "never pays out more than the shares burned");
    }

    /// Written off credit leaves creditBackedSupply so utilization stops counting it, but it must
    /// not become redeemable: no reserve arrived with the write off. Both amounts are excluded
    /// from unlockedSupply.
    function test_recognizeBadDebt_releasesCreditWithoutUnlockingIt() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.creditBackedSupply(), 100e18);
        assertEq(scoin.unlockedSupply(), 0, "no deposits, so nothing is redeemable");

        scoin.recognizeBadDebt(30e18);

        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.creditBackedSupply(), 70e18, "written off credit leaves the utilization base");
        assertEq(scoin.unlockedSupply(), 0, "but does not become redeemable against the reserve");
    }

    /// Covering retires written off supply against real cUSD, so the same backing stands behind
    /// fewer shares. This is the only route that takes the ratio all the way back to par.
    function test_coverBadDebt_restoresParWithoutNewReserve() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebt(100e18);

        uint256 backingBefore = scoin.totalAssets();
        uint256 reserveBefore = asset.balanceOf(address(scoin));

        vm.prank(treasury);
        uint256 covered = scoin.coverBadDebt(100e18);

        assertEq(covered, 100e18, "the whole shortfall is retired");
        assertEq(scoin.badDebt(), 0, "no shortfall left");
        assertEq(scoin.totalSupply(), 1_400e18, "supply shrinks by the burned cUSD");
        assertEq(scoin.totalAssets(), backingBefore, "backing is untouched");
        assertEq(asset.balanceOf(address(scoin)), reserveBefore, "and so is the reserve");
        assertEq(scoin.previewRedeem(100e18), 100e18, "shares redeem at par again");
    }

    /// Partial cover moves the ratio proportionally and leaves the rest outstanding.
    function test_coverBadDebt_partial() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebt(100e18);

        vm.prank(treasury);
        assertEq(scoin.coverBadDebt(40e18), 40e18, "covers what was asked");

        assertEq(scoin.badDebt(), 60e18, "the rest is still outstanding");
        assertEq(scoin.totalAssets(), 1_400e18, "backing unchanged");
        assertEq(scoin.totalSupply(), 1_460e18, "supply shrinks by the burned cUSD");
    }

    /// Overpaying is capped at the outstanding shortfall rather than burning the difference.
    function test_coverBadDebt_cappedAtOutstandingShortfall() public {
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebt(100e18);

        vm.prank(treasury);
        assertEq(scoin.coverBadDebt(type(uint256).max), 100e18, "capped at the shortfall");
        assertEq(scoin.balanceOf(treasury), 400e18, "only the shortfall was burned");
    }

    function test_coverBadDebt_withNoShortfall_reverts() public {
        scoin.mintCreditBacked(treasury, 100e18);

        vm.prank(treasury);
        vm.expectRevert(IStablecoin.NoBadDebt.selector);
        scoin.coverBadDebt(50e18);
    }

    function test_coverBadDebt_onlyAuthority() public {
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebt(100e18);

        vm.prank(bob);
        vm.expectRevert();
        scoin.coverBadDebt(100e18);
    }

    /// Burning cUSD without retiring the shortfall moves the ratio the wrong way, which is why a
    /// recovery has to route through coverBadDebt rather than a plain transfer and burn.
    function test_coverBadDebt_plainBurnWouldMakeTheRatioWorse() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebt(100e18);

        uint256 ratioBefore = scoin.totalAssets() * 1e27 / scoin.totalSupply();

        // burnCreditBacked is the closest thing to a plain burn; it drops supply but not badDebt
        scoin.mintCreditBacked(treasury, 100e18);
        scoin.burnCreditBacked(treasury, 100e18);
        uint256 ratioAfterPlainBurn = scoin.totalAssets() * 1e27 / scoin.totalSupply();
        assertEq(ratioAfterPlainBurn, ratioBefore, "a matched mint and burn is neutral");

        // burning supply that is already outstanding, without touching badDebt, is not
        vm.prank(treasury);
        scoin.transfer(bob, 100e18);
        scoin.burnCreditBacked(bob, 100e18);
        assertLt(scoin.totalAssets() * 1e27 / scoin.totalSupply(), ratioBefore, "ratio gets worse");
    }

    /// The redemption gate must never promise more than the reserve holds.
    function test_unlockedSupply_staysWithinTheReserve() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);

        assertEq(scoin.unlockedSupply(), 1_000e18, "only the deposits are redeemable");

        scoin.recognizeBadDebt(100e18);

        // the write off moves 100e18 out of creditBackedSupply and into badDebt, and the gate
        // excludes both, so the redeemable amount is unchanged rather than inflated by the loss
        uint256 unlocked = scoin.unlockedSupply();
        assertEq(unlocked, 1_000e18, "the write off does not unlock anything new");
        assertLe(scoin.previewRedeem(unlocked), asset.balanceOf(address(scoin)), "gate stays solvent");
    }

    function test_upgrade_authorized() public {
        Stablecoin newImpl = new Stablecoin();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
        assertEq(scoin.decimals(), 18);
    }

    function test_upgrade_unauthorized_reverts() public {
        Stablecoin newImpl = new Stablecoin();
        vm.prank(alice);
        vm.expectRevert();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
    }
}
