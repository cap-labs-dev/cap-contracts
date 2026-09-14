// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { IERC7540AsyncRedeem } from "../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IStablecoin } from "../../../contracts/interfaces/IStablecoin.sol";
import { CapRoles } from "../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockAeraVault } from "../../shared/mocks/MockAeraVault.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract StablecoinTest is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal asset;
    MockIRM internal irm;
    MockAeraVault internal reserve;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal governor = makeAddr("governor");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();
        reserve = new MockAeraVault();

        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(asset), "Cap USD", "cUSD", address(irm), address(reserve))
                )
            )
        );

        asset.mint(alice, 1_000e18);
        vm.prank(alice);
        asset.approve(address(scoin), type(uint256).max);

        // parking reserve is keeper maintenance; covering a shortfall is permissionless
        bytes4[] memory keeperSelectors = new bytes4[](2);
        keeperSelectors[0] = Stablecoin.invest.selector;
        keeperSelectors[1] = Stablecoin.recall.selector;
        _grantRoleForTarget(CapRoles.KEEPER, keeper, address(scoin), keeperSelectors);

        bytes4[] memory guardianSelectors = new bytes4[](3);
        guardianSelectors[0] = Stablecoin.recognizeBadDebtInReserve.selector;
        guardianSelectors[1] = Stablecoin.pause.selector;
        guardianSelectors[2] = Stablecoin.unpause.selector;
        _grantRoleForTarget(CapRoles.GUARDIAN, guardian, address(scoin), guardianSelectors);

        bytes4[] memory governorSelectors = new bytes4[](1);
        governorSelectors[0] = Stablecoin.setReserveVault.selector;
        _grantRoleForTarget(CapRoles.GOVERNOR, governor, address(scoin), governorSelectors);
    }

    /// @dev Bad debt only ever arises from a market writing off credit it minted, so the credit
    /// must exist before it can be written off. Mint it to a sink first to reach that state.
    function _writeOffCredit(uint256 amount) internal {
        scoin.mintCreditBacked(makeAddr("defaultedBorrower"), amount);
        scoin.recognizeBadDebtInCredit(amount);
    }

    function test_decimalsIs18() public view {
        assertEq(scoin.decimals(), 18);
    }

    /// @dev Live cUSD is ERC-2612. The 4626/7540 rewrite dropped permit, nonces, and
    /// DOMAIN_SEPARATOR; wallets and routers that approve by signature would have nowhere to go.
    function test_permitSetsAllowanceAndConsumesNonce() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        address spender = makeAddr("permitSpender");

        vm.prank(alice);
        scoin.deposit(100e18, owner);

        assertEq(scoin.nonces(owner), 0);
        assertTrue(scoin.DOMAIN_SEPARATOR() != bytes32(0));

        uint256 value = 40e18;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                scoin.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        scoin.nonces(owner),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        scoin.permit(owner, spender, value, deadline, v, r, s);

        assertEq(scoin.allowance(owner, spender), value);
        assertEq(scoin.nonces(owner), 1);

        vm.prank(spender);
        scoin.transferFrom(owner, spender, value);
        assertEq(scoin.balanceOf(spender), value);
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

    function test_transfer_betweenNonOptedHoldersDoesNotWriteTheVest() public {
        address earner = makeAddr("earner");
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);
        scoin.mintCreditBacked(earner, 1e18);
        vm.prank(earner);
        scoin.optIn();

        vm.warp(block.timestamp + 1 hours);
        uint256 lastUpdate = scoin.lastPremiumUpdate();

        vm.prank(alice);
        assertTrue(scoin.transfer(bob, 10e18));

        assertEq(scoin.balanceOf(alice), 90e18);
        assertEq(scoin.balanceOf(bob), 60e18);
        assertEq(scoin.lastPremiumUpdate(), lastUpdate, "neither earner moved, so the clock is left alone");
    }

    function test_transfer_nonOptedIsCheaperThanOptedOnceWarm() public {
        address earner = makeAddr("earner");
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);
        scoin.mintCreditBacked(earner, 20e18);
        vm.prank(earner);
        scoin.optIn();

        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        scoin.transfer(bob, 1e18);
        vm.prank(earner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        scoin.transfer(alice, 1e18);

        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        scoin.transfer(bob, 1e18);
        uint256 idle = vm.lastCallGas().gasTotalUsed;

        vm.prank(earner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        scoin.transfer(alice, 1e18);
        uint256 earning = vm.lastCallGas().gasTotalUsed;

        assertLt(idle, earning, "skipping the vest write has to show up in gas");
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

    function test_recognizeBadDebtInCredit_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.recognizeBadDebtInCredit(1e18);
    }

    function test_badDebt_reducesTotalAssets() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.totalAssets(), 100e18);
        scoin.recognizeBadDebtInCredit(30e18);
        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.backing(), 70e18, "recognized backing is supply net of the write-off");
        assertEq(scoin.totalAssets(), 70e18, "and totalAssets is that figure, in underlying units");
        assertLt(scoin.convertToAssets(70e18), 70e18, "the exit quote is the discounted one");
    }

    /// @dev Confirmed: 1,000 supply and 100 of bad debt is 900 of recognized backing. Feeding that
    /// 900 through the exit curve produced ~801.10, which is the quote for redeeming the
    /// outstanding supply, not the backing itself.
    function test_totalAssets_isRecognizedBackingNotTheExitDiscount() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        vm.prank(guardian);
        scoin.recognizeBadDebtInReserve(100e18);

        assertEq(scoin.totalSupply(), 1_000e18);
        assertEq(scoin.badDebt(), 100e18);
        assertEq(scoin.backing(), 900e18);
        assertEq(scoin.totalAssets(), 900e18, "recognized backing, not the discounted exit");
        assertApproxEqAbs(
            scoin.convertToAssets(900e18), 801.098901098901098901e18, 2, "801.10 is the exit quote for those 900"
        );
        assertEq(scoin.convertToAssets(scoin.totalSupply()), 900e18, "redeeming everything still pays the backing");
    }

    function test_recognizeBadDebtInReserve_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.recognizeBadDebtInReserve(1e18);
    }

    function test_recognizeBadDebtInReserve_socializesReserveLoss() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);
        uint256 rateUpdates = irm.updateCalls();

        vm.expectEmit(false, false, false, true);
        emit IStablecoin.BadDebtRecognizedInReserve(30e18);
        vm.prank(guardian);
        scoin.recognizeBadDebtInReserve(30e18);

        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.backing(), 120e18, "recognized backing is supply net of the write-off");
        assertEq(scoin.totalAssets(), 120e18);
        assertLt(scoin.convertToAssets(120e18), 120e18, "the exit quote is the discounted one");
        assertEq(scoin.creditBackedSupply(), 50e18, "reserve loss does not write off borrower credit");
        assertEq(irm.updateCalls(), rateUpdates, "reserve loss does not change utilization");
    }

    function test_recognizeBadDebtInCredit_revertsAboveSupply() public {
        scoin.mintCreditBacked(bob, 50e18);

        vm.expectRevert(IStablecoin.BadDebtExceedsSupply.selector);
        scoin.recognizeBadDebtInCredit(50e18 + 1);
    }

    function test_recognizeBadDebtInReserve_revertsAboveSupply() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);

        vm.prank(guardian);
        vm.expectRevert(IStablecoin.BadDebtExceedsSupply.selector);
        scoin.recognizeBadDebtInReserve(100e18 + 1);
    }

    /// @dev A reserve loss that fits under total supply can still exceed the reserve-backed
    /// slice. The extra would be charged against credit that a later repay burns, and
    /// {backing} would underflow.
    function test_recognizeBadDebtInReserve_revertsAboveReserveBackedSupply() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);

        vm.prank(guardian);
        vm.expectRevert(IStablecoin.BadDebtExceedsSupply.selector);
        scoin.recognizeBadDebtInReserve(100e18 + 1);
    }

    function test_recognizeBadDebtInReserve_thenRepayKeepsBackingSolvent() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);

        vm.prank(guardian);
        scoin.recognizeBadDebtInReserve(100e18);

        assertEq(scoin.badDebt() + scoin.creditBackedSupply(), scoin.totalSupply());
        scoin.burnCreditBacked(bob, 50e18);

        assertEq(scoin.backing(), 0, "the repaid credit is not subtracted from a reserve shortfall");
        assertEq(scoin.badDebt(), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
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
                    (address(accessManager), address(underlying), "Cap USD", "cUSD", address(irm), address(0))
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

    function test_totalAssets_isUnderlyingUnits() public {
        Stablecoin usdc = _stablecoinOn(6);
        MockERC20 underlying = MockERC20(usdc.asset());
        underlying.mint(alice, 1e6);
        vm.prank(alice);
        underlying.approve(address(usdc), type(uint256).max);
        vm.prank(alice);
        usdc.deposit(1e6, alice);

        assertEq(usdc.totalSupply(), 1e18);
        assertEq(usdc.backing(), 1e18, "backing stays in share units");
        assertEq(usdc.totalAssets(), 1e6, "integrators read USDC units, not share units");
        assertEq(usdc.totalAssets(), usdc.convertToAssets(usdc.totalSupply()));
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
                Stablecoin.initialize,
                (address(accessManager), address(wide), "Cap USD", "cUSD", address(irm), address(0))
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
        assertEq(scoin.maxInstantRedeem(alice), 100e18);
        assertEq(scoin.maxRedeem(alice), 0, "claimable only after a request");
    }

    function test_previewRedeemAndWithdraw_revert() public {
        vm.expectRevert(IERC7540AsyncRedeem.PreviewNotSupported.selector);
        scoin.previewRedeem(1e18);
        vm.expectRevert(IERC7540AsyncRedeem.PreviewNotSupported.selector);
        scoin.previewWithdraw(1e18);
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

        assertApproxEqAbs(scoin.convertToAssets(50e18), 37.313432835820895522e18, 2, "priced on the shortfall curve");
    }

    /// Holding less than the shortfall no longer zeroes the redeemer out. Supply 160e18 against
    /// 100e18: redeeming 40e18 leaves 120e18, retaining 120 * 160 * 100 / (160 * 100 + 120 * 60)
    /// = 82.7586... of the backing, so the payout is the 17.2413... left over.
    function test_previewRedeem_withBadDebt_sharesBelowBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(60e18);

        assertApproxEqAbs(scoin.convertToAssets(40e18), 17.241379310344827586e18, 2, "paid something, not zero");
    }

    /// Redeeming the entire supply pays out exactly the reserve and no more, so the curve can
    /// never promise assets that are not there.
    function test_previewRedeem_wholeSupplyPaysExactlyTheBacking() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

        assertEq(scoin.backing(), 1_400e18, "recognized backing is supply net of the write-off");
        assertEq(scoin.totalAssets(), 1_400e18, "and totalAssets reports that, not the exit discount");
        assertEq(scoin.convertToAssets(scoin.totalSupply()), 1_400e18, "redeeming everything pays the backing");
        assertLt(scoin.convertToAssets(1_400e18), 1_400e18, "redeeming only the outstanding is discounted");
    }

    /// The old conversion paid early redeemers more than their share and let a single large
    /// redemption clear the whole shortfall while absorbing only a fraction of it. The reserve
    /// must fall by exactly the payout.
    function test_redeem_neverPaysMoreThanItReducesTotalAssets() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

        uint256 assetsBefore = scoin.totalAssets();
        uint256 heldBefore = asset.balanceOf(address(scoin));

        vm.prank(alice);
        uint256 paid = scoin.instantRedeem(1_000e18, alice, alice);

        // the 500e18 left behind retains 500 * 1500 * 1400 / (1500 * 1400 + 500 * 100) of the
        // backing, so alice takes the 911.62... that leaves over and absorbs the 88.37... gap
        assertApproxEqAbs(paid, 911.627906976744186046e18, 2, "priced on the shortfall curve");
        assertEq(assetsBefore - scoin.totalAssets(), paid, "recognized backing falls by the payout");
        assertEq(heldBefore - asset.balanceOf(address(scoin)), paid, "the reserve falls by exactly what was paid");
        assertApproxEqAbs(scoin.badDebt(), 100e18 - (1_000e18 - paid), 2, "absorbs exactly what it left behind");
    }

    /// @dev The property the shortfall curve rests on, and the reason chopping a redemption up
    /// cannot beat taking it in one call: `badDebt / (totalSupply * outstandingSupply)` is conserved by
    /// a redemption. Since what a redemption retains is `remaining / (1 + k * remaining)` for that
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
        scoin.recognizeBadDebtInCredit(100e18);

        uint256 k = _shortfallInvariant();
        uint256 whole = scoin.convertToAssets(600e18);

        // the same 600e18 exit, taken a slice at a time and re-priced against the state each
        // slice leaves behind
        uint256 taken;
        uint256 each = 600e18 / slices;
        for (uint256 i; i < slices; ++i) {
            uint256 shares = i + 1 == slices ? 600e18 - each * (slices - 1) : each;
            vm.prank(alice);
            taken += scoin.instantRedeem(shares, alice, alice);
            assertApproxEqRel(_shortfallInvariant(), k, 1e6, "the invariant survives every slice");
        }

        assertApproxEqRel(taken, whole, 1e6, "and slicing pays no more than the single call");
    }

    /// @dev `badDebt * 1e36 / (totalSupply * outstandingSupply)`, scaled so the ratio is comparable
    /// across states without losing it to integer division
    function _shortfallInvariant() internal view returns (uint256 k) {
        k = Math.mulDiv(scoin.badDebt(), 1e36, scoin.totalSupply() * (scoin.totalSupply() - scoin.badDebt()));
    }

    /// quoteWithdraw must be the inverse of convertToAssets above the shortfall.
    function test_previewWithdraw_isInverseOfPreviewRedeem() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);

        uint256 assets = scoin.convertToAssets(50e18);
        assertEq(scoin.quoteWithdraw(assets), 50e18, "round trips exactly");
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

        uint256 below = scoin.quoteWithdraw(10e18);
        uint256 above = scoin.quoteWithdraw(50e18);
        assertGt(below, 0);
        assertGt(above, below);
    }

    /// @dev Three-arg withdraw must pay the asset target once, even when the ceil quote is
    /// split across receipts. The shortfall curve is nonlinear, so converting each fragment
    /// would not sum to the single-call price — or to the requested assets.
    function test_fifoWithdraw_paysExactAssetsOnTheShortfallCurve() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        _writeOffCredit(100e18);

        uint256 assets = 10e18;
        uint256 shares = scoin.quoteWithdraw(assets);
        assertGt(shares, assets, "the curve asks for more shares than assets");

        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 instantShares = scoin.instantWithdraw(assets, alice, alice);
        uint256 instantBad = scoin.badDebt();
        uint256 instantReserve = asset.balanceOf(address(scoin));
        vm.revertToState(snapshot);

        uint256 first = shares / 3;
        uint256 second = shares / 3;
        uint256 third = shares - first - second;
        uint256 sliced = scoin.convertToAssets(first) + scoin.convertToAssets(second) + scoin.convertToAssets(third);

        vm.startPrank(alice);
        scoin.requestRedeem(first, alice, alice);
        scoin.requestRedeem(second, alice, alice);
        scoin.requestRedeem(third, alice, alice);
        uint256 burned = scoin.withdraw(assets, alice, alice);
        vm.stopPrank();

        assertEq(burned, shares, "all quoted shares were consumed");
        assertEq(burned, instantShares, "same shares as the instant path");
        assertEq(asset.balanceOf(alice), assets, "paid the requested assets exactly");
        assertEq(scoin.badDebt(), instantBad, "same shortfall retired");
        assertEq(asset.balanceOf(address(scoin)), instantReserve, "same reserve left");
        assertTrue(sliced != assets, "per-fragment conversion is not the settlement");
    }

    /// @dev One underlying atom whose ceil quote spans 1-share receipts. Each convertToAssets(1)
    /// is zero on the curve; the settlement must still pay the atom.
    function test_fifoWithdraw_paysOneAtomAcrossDustReceipts() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        _writeOffCredit(100e18);

        uint256 shares = scoin.quoteWithdraw(1);
        assertGt(shares, 0, "the atom costs some shares");
        assertEq(scoin.convertToAssets(1), 0, "a single share pays nothing");

        vm.startPrank(alice);
        for (uint256 i; i < shares; ++i) {
            scoin.requestRedeem(1, alice, alice);
        }
        uint256 burned = scoin.withdraw(1, alice, alice);
        vm.stopPrank();

        assertEq(burned, shares, "all quoted shares were consumed");
        assertEq(asset.balanceOf(alice), 1, "paid the atom");
    }

    function test_instantRedeem_absorbsBadDebt_whenSharesExceedDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        _writeOffCredit(20e18);
        uint256 irmBefore = irm.updateCalls();
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        // 120e18 supply against 100e18 of backing, redeeming 50e18; see previewRedeem above
        vm.prank(alice);
        uint256 assets = scoin.instantRedeem(50e18, alice, alice);

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
        uint256 assets = scoin.instantRedeem(40e18, alice, alice);

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

        uint256 small = scoin.convertToAssets(1e18);
        assertGt(small, 0, "nobody is zeroed out");
        assertApproxEqRel(scoin.convertToAssets(10e18), small * 10, 0.01e18, "10x holder gets 10x");
    }

    /// Splitting a redemption must not beat doing it in one go. Pricing off the instantaneous
    /// ratio would fail this, because each redemption lifts the ratio for the next one and a
    /// redeemer could harvest their own repair a slice at a time.
    function testFuzz_redeem_splittingGainsNothing(uint256 written, uint256 each, uint256 chunks) public {
        written = bound(written, 1e18, 500e18);
        chunks = bound(chunks, 2, 20);

        uint256 snapshot = vm.snapshotState();
        _seedWrittenOffPool(written);
        uint256 maxShares = scoin.maxInstantRedeem(alice);
        vm.revertToState(snapshot);

        // both legs redeem exactly the same total, so the comparison is like for like
        each = bound(each, 1e15, maxShares / chunks);
        uint256 total = each * chunks;

        _seedWrittenOffPool(written);
        vm.prank(alice);
        uint256 atOnce = scoin.instantRedeem(total, alice, alice);
        vm.revertToState(snapshot);

        _seedWrittenOffPool(written);
        uint256 split;
        for (uint256 i; i < chunks; ++i) {
            vm.prank(alice);
            split += scoin.instantRedeem(each, alice, alice);
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

        uint256 backingBefore = scoin.totalSupply() - scoin.badDebt();
        uint256 ratioBefore = backingBefore * 1e27 / scoin.totalSupply();
        uint256 shares = 300e18;

        // the redeemer is paid strictly less than their pro-rata share of the backing
        uint256 assets = scoin.convertToAssets(shares);
        assertLt(assets, shares * ratioBefore / 1e27, "priced below the pool ratio");

        vm.prank(alice);
        scoin.instantRedeem(shares, alice, alice);

        uint256 ratioAfter = (scoin.totalSupply() - scoin.badDebt()) * 1e27 / scoin.totalSupply();
        assertGt(ratioAfter, ratioBefore, "the peg moves back toward par");
    }

    /// Whatever the payout, the reserve must fall by exactly that amount, so no part of the loss
    /// is ever erased from the books or double counted.
    function testFuzz_redeem_totalAssetsFallsByExactlyThePayout(uint256 deposited, uint256 written, uint256 shares)
        public
    {
        deposited = bound(deposited, 1e18, 1_000e18);
        written = bound(written, 1e18, 1_000e18);
        vm.prank(alice);
        scoin.deposit(deposited, alice);
        _writeOffCredit(written);

        shares = bound(shares, 1, scoin.maxInstantRedeem(alice));
        uint256 heldBefore = asset.balanceOf(address(scoin));
        uint256 assetsBefore = scoin.totalAssets();

        vm.prank(alice);
        uint256 paid = scoin.instantRedeem(shares, alice, alice);

        assertEq(heldBefore - asset.balanceOf(address(scoin)), paid, "the reserve tracks the payout exactly");
        assertEq(assetsBefore - scoin.totalAssets(), paid, "recognized backing falls by the same amount");
        assertLe(paid, shares, "never pays out more than the shares burned");
    }

    /// Written off credit leaves creditBackedSupply so utilization stops counting it, but it must
    /// not become redeemable: no reserve arrived with the write off. Both amounts are excluded
    /// from unlockedSupply.
    function test_recognizeBadDebt_releasesCreditWithoutUnlockingIt() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.creditBackedSupply(), 100e18);
        assertEq(scoin.unlockedSupply(), 0, "no deposits, so nothing is redeemable");

        scoin.recognizeBadDebtInCredit(30e18);

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
        scoin.recognizeBadDebtInCredit(100e18);

        uint256 backingBefore = scoin.totalSupply() - scoin.badDebt();
        uint256 reserveBefore = asset.balanceOf(address(scoin));

        vm.prank(treasury);
        uint256 covered = scoin.coverBadDebt(100e18);

        assertEq(covered, 100e18, "the whole shortfall is retired");
        assertEq(scoin.badDebt(), 0, "no shortfall left");
        assertEq(scoin.totalSupply(), 1_400e18, "supply shrinks by the burned cUSD");
        assertEq(scoin.totalSupply() - scoin.badDebt(), backingBefore, "outstanding supply is untouched");
        assertEq(scoin.totalAssets(), scoin.totalSupply(), "and now redeems at par");
        assertEq(asset.balanceOf(address(scoin)), reserveBefore, "and so is the reserve");
        assertEq(scoin.convertToAssets(100e18), 100e18, "shares redeem at par again");
    }

    /// Partial cover moves the ratio proportionally and leaves the rest outstanding.
    function test_coverBadDebt_partial() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

        vm.prank(treasury);
        assertEq(scoin.coverBadDebt(40e18), 40e18, "covers what was asked");

        assertEq(scoin.badDebt(), 60e18, "the rest is still outstanding");
        assertEq(scoin.totalSupply() - scoin.badDebt(), 1_400e18, "outstanding supply unchanged");
        assertEq(scoin.totalSupply(), 1_460e18, "supply shrinks by the burned cUSD");
    }

    /// Overpaying is capped at the outstanding shortfall rather than burning the difference.
    function test_coverBadDebt_cappedAtOutstandingShortfall() public {
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

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

    function test_coverBadDebt_isPermissionless() public {
        scoin.mintCreditBacked(bob, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

        vm.prank(bob);
        assertEq(scoin.coverBadDebt(100e18), 100e18);
        assertEq(scoin.badDebt(), 0);
        assertEq(scoin.balanceOf(bob), 400e18);
    }

    /// Burning cUSD without retiring the shortfall moves the ratio the wrong way, which is why a
    /// recovery has to route through coverBadDebt rather than a plain transfer and burn.
    function test_coverBadDebt_plainBurnWouldMakeTheRatioWorse() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(treasury, 500e18);
        scoin.recognizeBadDebtInCredit(100e18);

        uint256 ratioBefore = (scoin.totalSupply() - scoin.badDebt()) * 1e27 / scoin.totalSupply();

        // burnCreditBacked is the closest thing to a plain burn; it drops supply but not badDebt
        scoin.mintCreditBacked(treasury, 100e18);
        scoin.burnCreditBacked(treasury, 100e18);
        uint256 ratioAfterPlainBurn = (scoin.totalSupply() - scoin.badDebt()) * 1e27 / scoin.totalSupply();
        assertEq(ratioAfterPlainBurn, ratioBefore, "a matched mint and burn is neutral");

        // burning supply that is already outstanding, without touching badDebt, is not
        vm.prank(treasury);
        assertTrue(scoin.transfer(bob, 100e18));
        scoin.burnCreditBacked(bob, 100e18);
        assertLt((scoin.totalSupply() - scoin.badDebt()) * 1e27 / scoin.totalSupply(), ratioBefore, "ratio gets worse");
    }

    /// The redemption gate must never promise more than the reserve holds.
    function test_unlockedSupply_staysWithinTheReserve() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(bob, 500e18);

        assertEq(scoin.unlockedSupply(), 1_000e18, "only the deposits are redeemable");

        scoin.recognizeBadDebtInCredit(100e18);

        // the write off moves 100e18 out of creditBackedSupply and into badDebt, and the gate
        // excludes both, so the redeemable amount is unchanged rather than inflated by the loss
        uint256 unlocked = scoin.unlockedSupply();
        assertEq(unlocked, 1_000e18, "the write off does not unlock anything new");
        assertLe(scoin.convertToAssets(unlocked), asset.balanceOf(address(scoin)), "gate stays solvent");
    }

    function test_pause_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.pause();

        vm.prank(guardian);
        scoin.pause();
        assertTrue(scoin.paused());

        vm.prank(alice);
        vm.expectRevert();
        scoin.unpause();

        vm.prank(guardian);
        scoin.unpause();
        assertFalse(scoin.paused());
    }

    function test_pause_blocksMintAndBurn() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);

        vm.prank(guardian);
        scoin.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        scoin.deposit(1e18, alice);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        scoin.mintCreditBacked(bob, 1e18);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        scoin.fundCreditBacked(1e18);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        scoin.burnCreditBacked(bob, 1e18);

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        scoin.instantRedeem(1e18, alice, alice);
    }

    function test_pause_allowsTransfers() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);

        vm.prank(guardian);
        scoin.pause();

        vm.prank(alice);
        assertTrue(scoin.transfer(bob, 10e18));
        assertEq(scoin.balanceOf(alice), 90e18);
        assertEq(scoin.balanceOf(bob), 10e18);
    }

    function test_unpause_restoresMintAndBurn() public {
        vm.prank(guardian);
        scoin.pause();
        vm.prank(guardian);
        scoin.unpause();

        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(bob, 50e18);
        scoin.burnCreditBacked(bob, 20e18);

        assertEq(scoin.balanceOf(alice), 100e18);
        assertEq(scoin.balanceOf(bob), 30e18);
        assertEq(scoin.creditBackedSupply(), 30e18);
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        scoin.initialize(address(accessManager), address(asset), "Cap USD", "cUSD", address(irm), address(reserve));
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

    function test_fund_depositsUnderlyingAndVestsTheShares() public {
        asset.mint(address(this), 10e18);
        asset.approve(address(scoin), 10e18);

        uint256 shares = scoin.previewDeposit(10e18);
        scoin.fund(10e18);

        assertEq(scoin.balanceOf(address(scoin)), shares);
        assertEq(scoin.creditBackedSupply(), 0, "backed by the deposit, not by credit");
        assertEq(asset.balanceOf(address(scoin)), 10e18);
        assertEq(scoin.remaining(), shares);
        assertEq(scoin.vested(), 0);
        assertEq(scoin.stablecoin(), address(scoin));
    }

    function test_fund_isPermissionless() public {
        vm.prank(alice);
        scoin.fund(10e18);

        assertEq(scoin.balanceOf(address(scoin)), 10e18);
        assertEq(scoin.remaining(), 10e18);
        assertEq(asset.balanceOf(address(scoin)), 10e18);
    }

    function test_fund_theReserveVaultCanReturnYield() public {
        asset.mint(address(reserve), 10e18);
        vm.startPrank(address(reserve));
        asset.approve(address(scoin), 10e18);
        scoin.fund(10e18);
        vm.stopPrank();

        assertEq(scoin.balanceOf(address(scoin)), 10e18);
        assertEq(scoin.remaining(), 10e18);
        assertEq(asset.balanceOf(address(reserve)), 0);
        assertEq(asset.balanceOf(address(scoin)), 10e18);
    }

    function test_fundCreditBacked_mintsToItselfAndOpensTheRemainder() public {
        scoin.fundCreditBacked(10e18);
        assertEq(scoin.balanceOf(address(scoin)), 10e18);
        assertEq(scoin.creditBackedSupply(), 10e18);
        assertEq(scoin.remaining(), 10e18);
        assertEq(scoin.vested(), 0);
        assertEq(scoin.stablecoin(), address(scoin));
    }

    function test_fundCreditBacked_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.fundCreditBacked(1e18);
    }

    function test_optInHolderClaimsVestedPremium() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        vm.prank(alice);
        scoin.optIn();

        scoin.fundCreditBacked(10e18);
        vm.warp(block.timestamp + 20 * scoin.vestingPeriod());

        uint256 owed = scoin.claimable(alice);
        assertApproxEqRel(owed, 10e18, 1e12);

        vm.prank(alice);
        uint256 paid = scoin.claim(alice);
        assertEq(paid, owed);
        assertEq(scoin.balanceOf(alice), 100e18 + paid);
        assertEq(scoin.claimable(alice), 0);
    }

    /// @dev Queued redemptions sit in this contract's own balance. Paying premium from the
    ///      raw balance would spend that escrow; spendable is the remainder after the queue.
    function test_claimDoesNotSpendRedemptionEscrow() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        vm.prank(alice);
        scoin.optIn();

        scoin.fundCreditBacked(10e18);
        vm.warp(block.timestamp + 20 * scoin.vestingPeriod());

        vm.prank(alice);
        uint256 id = scoin.requestRedeem(50e18, alice, alice);
        assertEq(scoin.redemptionQueue(), 50e18);
        assertEq(scoin.balanceOf(address(scoin)), 60e18, "10 of premium plus 50 escrowed");

        uint256 owed = scoin.claimable(alice);
        vm.prank(alice);
        uint256 paid = scoin.claim(alice);

        assertEq(paid, owed <= 10e18 ? owed : 10e18, "only the unescrowed pot is paid");
        assertEq(scoin.redemptionQueue(), 50e18, "the queued redeem is untouched");
        assertEq(scoin.pendingRedeemRequest(id, alice) + scoin.claimableRedeemRequest(id, alice), 50e18);
        assertEq(scoin.balanceOf(address(scoin)), 60e18 - paid);
    }

    function test_nonOptedHolderEarnsNothingOnTheStablecoin() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);

        scoin.fundCreditBacked(10e18);
        vm.warp(block.timestamp + 20 * scoin.vestingPeriod());

        assertFalse(scoin.optedIn(alice));
        assertEq(scoin.claimable(alice), 0);
        assertEq(scoin.stakedSupply(), 0);
    }

    function test_idleStablecoinFreezesUntilSomeoneOptsIn() public {
        scoin.fundCreditBacked(10e18);
        vm.warp(block.timestamp + scoin.vestingPeriod());
        uint256 pot = scoin.remaining() + scoin.vested();

        vm.prank(alice);
        scoin.deposit(100e18, alice);
        vm.prank(alice);
        scoin.optIn();

        assertEq(scoin.claimable(alice), 0, "the idle window is not hers");
        assertEq(scoin.remaining(), pot, "and the remainder is still held");
    }

    // ── idle reserve can sit in Aera without changing the share price ─────────

    function test_initialize_setsReserveVault() public view {
        assertEq(scoin.reserveVault(), address(reserve));
    }

    function test_setReserveVault_onlyGovernor() public {
        MockAeraVault replacement = new MockAeraVault();
        vm.prank(keeper);
        vm.expectRevert();
        scoin.setReserveVault(address(replacement));
    }

    function test_setReserveVault_updatesAndAllowsZero() public {
        MockAeraVault replacement = new MockAeraVault();

        vm.expectEmit(true, true, false, true, address(scoin));
        emit IStablecoin.SetReserveVault(address(reserve), address(replacement));
        vm.prank(governor);
        scoin.setReserveVault(address(replacement));
        assertEq(scoin.reserveVault(), address(replacement));

        vm.prank(governor);
        scoin.setReserveVault(address(0));
        assertEq(scoin.reserveVault(), address(0));
    }

    function test_invest_movesReserveAndLeavesSharePrice() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        assertEq(scoin.totalAssets(), 1_000e18);

        vm.prank(keeper);
        scoin.invest(400e18);

        assertEq(asset.balanceOf(address(scoin)), 600e18, "reserve left on the vault");
        assertEq(asset.balanceOf(address(reserve)), 400e18, "parked in Aera");
        assertEq(scoin.totalAssets(), 1_000e18, "accounting is not the token balance");
        assertEq(asset.allowance(address(scoin), address(reserve)), 0, "Aera requires a spent allowance");
    }

    function test_recall_returnsReserve() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);

        vm.prank(keeper);
        scoin.invest(400e18);
        vm.prank(keeper);
        scoin.recall(400e18);

        assertEq(asset.balanceOf(address(scoin)), 1_000e18);
        assertEq(asset.balanceOf(address(reserve)), 0);
        assertEq(scoin.totalAssets(), 1_000e18);
    }

    function test_invest_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.invest(1e18);
    }

    function test_recall_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.recall(1e18);
    }

    /// Parking reserve does not change what a share is worth, but the tokens still have to be
    /// back on this contract before anyone can redeem them.
    function test_redeemAfterInvest_needsARecall() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);

        vm.prank(keeper);
        scoin.invest(100e18);

        vm.prank(alice);
        vm.expectRevert();
        scoin.instantRedeem(100e18, alice, alice);

        vm.prank(keeper);
        scoin.recall(100e18);

        vm.prank(alice);
        scoin.instantRedeem(100e18, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000e18);
    }
}
