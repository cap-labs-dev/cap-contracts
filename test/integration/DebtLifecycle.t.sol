// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { WadRayMath } from "../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Pins how a market's debt behaves across its life: drawn against a credit-backed mint,
/// priced by a continuous term curve, rolled when it falls overdue, liquidated when it breaches,
/// and written off when it cannot be recovered. Each test is a bug that was real once, so a
/// regression here is a repeat rather than a novelty.
contract DebtLifecycleTest is CapDeployer {
    using WadRayMath for uint256;

    uint256 internal constant PRINCIPAL = 1_000e18;

    function setUp() public {
        _deployCap();
    }

    function _readyFixed() internal returns (FixedMarket market) {
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
    }

    // ── debt is always matched by a credit-backed mint ───────────────────────

    /// Every unit of debt a floating market accrues must be matched by a credit-backed mint,
    /// including across a market multiplier change and with an empty junior tranche whose premium
    /// weight becomes leftover.
    function test_invariant_floatingDebtMatchesCreditBackedSupply() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 180 days);
        bundle.market.chargePremium();

        assertEq(bundle.market.totalDebt(), stablecoin.creditBackedSupply(), "debt backed after accrual");

        uint256 debtBefore = bundle.market.totalDebt();
        bundle.market.setMarketMultiplier(2e27);
        assertEq(bundle.market.totalDebt(), debtBefore, "multiplier change does not rescale principal");
        assertEq(bundle.market.totalDebt(), stablecoin.creditBackedSupply(), "debt backed after multiplier");

        vm.warp(block.timestamp + 180 days);
        bundle.market.chargePremium();
        assertEq(bundle.market.totalDebt(), stablecoin.creditBackedSupply(), "debt backed at the higher rate");
    }

    // ── the term multiplier is a single continuous line ──────────────────────

    /// The curve must be continuous and monotonically decreasing over the whole range, so a
    /// borrower can never find a cheaper term by moving one wei across a boundary. It must also
    /// stay at or above one ray, so no term escapes the liquidity premium entirely.
    function testFuzz_termMultiplier_decreasesMonotonicallyAndNeverBelowOneRay(uint256 lower, uint256 gap) public {
        irm.setTermMultiplierSlope(1e27);
        lower = bound(lower, 0, 2e27);
        gap = bound(gap, 0, 2e27 - lower);

        uint256 atLower = irm.termMultiplier(lower);
        uint256 atUpper = irm.termMultiplier(lower + gap);

        assertGe(atLower, atUpper, "a longer term is never dearer");
        assertGe(atUpper, 1e27, "no term is ever free");
    }

    // ── overdue loans are rolled and charged, not liquidated ─────────────────

    /// extendAdmin is the overdue path. It only opens once the grace period has passed, and it
    /// rolls the loan a full term forward from now while charging premium on the arrears.
    function test_extendAdmin_rollsOverdueLoanAndGrowsDebt() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);
        uint256 originalExpiry = market.expiry(id);

        // still inside the grace period, so the keeper cannot roll it yet
        vm.warp(originalExpiry + market.grace() - 1);
        vm.expectRevert(IFixedMarket.StillInGracePeriod.selector);
        market.extendAdmin(id, 7 days);

        // three days past expiry, one of which was grace
        vm.warp(originalExpiry + 3 days);
        uint256 debtBefore = market.debt(id);

        uint256 actual = market.extendAdmin(id, 7 days);

        assertEq(actual, 10 days, "arrears of 3 days plus the 7 day term");
        assertEq(market.expiry(id), block.timestamp + 7 days, "new expiry is a full term from now");
        assertGt(market.debt(id), debtBefore, "borrower is charged for the arrears and the new term");
    }

    /// A loan far past expiry must still be rollable even though the arrears exceed the maximum
    /// term. Only the requested new term is bound by the term limits.
    function test_extendAdmin_arrearsMayExceedMaximumTerm() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.warp(market.expiry(id) + 365 days);

        uint256 actual = market.extendAdmin(id, type(uint256).max);

        assertEq(actual, 365 days + 30 days, "a year of arrears plus the 30 day maximum term");
        assertEq(market.expiry(id), block.timestamp + 30 days, "rolled a maximum term from now");
    }

    /// The requested term is still bound by the maximum, which the old code let the arrears bypass.
    function test_extendAdmin_requestedTermAboveMaximum_reverts() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.warp(market.expiry(id) + market.grace() + 1);

        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extendAdmin(id, 31 days);
    }

    /// `type(uint256).max` used to overflow on the expired branch of extend.
    function test_extend_maxAfterExpiry_rollsAMaximumTerm() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.warp(market.expiry(id) + 2 days);

        uint256 actual = market.extend(id, type(uint256).max);

        assertEq(actual, 2 days + 30 days, "arrears plus the maximum term");
        assertEq(market.expiry(id), block.timestamp + 30 days, "rolled a maximum term from now");
    }

    /// A live loan keeps the existing behaviour: extend up to the room left under the maximum.
    function test_extend_liveLoanIsBoundedByRemainingRoom() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        assertEq(market.extend(id, type(uint256).max), 29 days, "fills the room under the maximum");

        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extend(id, 1 days);
    }

    // ── unrecoverable debt can be written off ────────────────────────────────

    /// The guardian can write off with the tranches still full, which is the case that matters:
    /// a liquidation nobody finds profitable never happens, so the shortfall would otherwise just
    /// compound. The amount comes from the tranches, and the debt left behind is exactly what the
    /// remaining collateral can still clear at the liquidation bonus.
    function test_writeOff_clearsShortfallWithTranchesUntouched() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 1_000e18);

        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 500e18);

        // collateral falls from $1 to $0.10, so 1000 tokens now back only $100 of the $500 debt
        oracle.setPrice(address(collateral), 0.1e18);
        assertEq(bundle.market.totalCapital(), 100e18, "capital repriced");

        // $100 of collateral can only clear $100 / 1.02 of debt once the bonus is paid
        uint256 recoverable = bundle.market.recoverableDebt();
        assertApproxEqRel(recoverable, 98.04e18, 0.001e18, "capital discounted by the bonus");

        uint256 shortfall = bundle.market.unrecoverableDebt();
        assertEq(shortfall, bundle.market.totalDebt() - recoverable, "the rest is unrecoverable");

        uint256 creditBefore = stablecoin.creditBackedSupply();
        uint256 written = bundle.market.writeOff();

        assertEq(written, shortfall, "the shortfall is written off");
        assertApproxEqAbs(bundle.market.totalDebt(), recoverable, 1, "debt left at the recoverable level");
        assertEq(stablecoin.badDebt(), shortfall, "loss is recorded as bad debt");
        assertEq(stablecoin.creditBackedSupply(), creditBefore - shortfall, "credit backing is released");

        // nothing is left unrecoverable, so a second write off has nothing to do
        assertEq(bundle.market.unrecoverableDebt(), 0, "shortfall is fully absorbed");
        vm.expectRevert(IBaseMarket.InvalidAmount.selector);
        bundle.market.writeOff();

        // and the remainder is still liquidatable, so the collateral is not stranded
        assertGt(bundle.market.maxLiquidatable(), 0, "liquidation stays viable");
    }

    /// A market whose collateral still covers its debt has nothing to write off.
    function test_writeOff_whenFullyCollateralised_reverts() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 400e18);

        assertEq(bundle.market.unrecoverableDebt(), 0, "collateral covers the debt");
        vm.expectRevert(IBaseMarket.InvalidAmount.selector);
        bundle.market.writeOff();
    }

    /// A fixed market write off is per loan but still capped by the market wide shortfall, so the
    /// guardian chooses which loans absorb it without being able to write off more than the gap.
    function test_writeOff_fixedLoanIsCappedByMarketShortfall() public {
        FixedMarket market = _readyFixed();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 4_000e18, 30 days);

        oracle.setPrice(address(collateral), 0.1e18);

        uint256 shortfall = market.unrecoverableDebt();
        assertGt(shortfall, 0, "market is short");
        assertLt(shortfall, market.debt(id), "but the loan is larger than the shortfall");

        uint256 loanBefore = market.debt(id);
        uint256 written = market.writeOff(id);

        assertEq(written, shortfall, "capped at the market shortfall, not the whole loan");
        assertEq(market.debt(id), loanBefore - shortfall, "loan keeps its recoverable debt");
        assertEq(market.unrecoverableDebt(), 0, "shortfall is absorbed");
    }

    /// Liquidation pays the plain bonus on the face value of the cUSD repaid, and outstanding bad
    /// debt does not change that. Minting is always available at par, so a dollar is what it costs
    /// to acquire a cUSD however the token happens to trade; discounting the collateral by the
    /// backing ratio would underpay liquidators and stall liquidation when it is most needed.
    function test_liquidate_paysPlainBonusRegardlessOfBadDebt() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 1_000e18);

        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 500e18);

        oracle.setPrice(address(collateral), 0.1e18);
        bundle.market.writeOff();
        assertGt(stablecoin.badDebt(), 0, "the supply is carrying a loss");

        uint256 repayAmount = bundle.market.maxLiquidatable() / 2;
        _mintStable(defaultLiquidator, repayAmount);

        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashedValue) = bundle.market.liquidate(defaultLiquidator, repayAmount);

        assertApproxEqRel(slashedValue, repaid.rayMul(1e27 + irm.liquidationBonus()), 0.001e18, "plain bonus");
    }

    // ── a zero oracle price fails closed ─────────────────────────────────────

    function test_zeroPrice_revertsInsteadOfDividingByZero() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 10_000e18);

        oracle.setPrice(address(collateral), 0);

        vm.expectRevert(ITranche.InvalidPrice.selector);
        bundle.tranche0.totalCapital();

        vm.expectRevert(ITranche.InvalidPrice.selector);
        bundle.tranche0.unlockedSupply();
    }

    // ── term limits are validated and adjustable ─────────────────────────────

    function test_setTermLimits_updatesBothBounds() public {
        FixedMarket market = _readyFixed();

        market.setTermLimits(90 days, 7 days);

        assertEq(market.maximumTermLimit(), 90 days, "maximum updated");
        assertEq(market.minimumTermLimit(), 7 days, "minimum updated");

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 60 days);
        assertEq(market.expiry(id), block.timestamp + 60 days, "a term inside the new range is accepted");
    }

    function test_setTermLimits_invalid_reverts() public {
        FixedMarket market = _readyFixed();

        vm.expectRevert(IFixedMarket.InvalidTermLimits.selector);
        market.setTermLimits(0, 0);

        vm.expectRevert(IFixedMarket.InvalidTermLimits.selector);
        market.setTermLimits(7 days, 8 days);
    }

    function test_createFixedMarket_withZeroMaximumTerm_reverts() public {
        uint256[] memory weights = capConfig.defaultTrancheWeights;
        vm.expectRevert(IFixedMarket.InvalidTermLimits.selector);
        registry.createFixedMarket(
            address(collateral), "Bad", defaultMarketOwner, defaultBorrower, 0, 0, 1 days, weights
        );
    }

    // ── vault operator rights track tranche registration ─────────────────────

    function test_trancheOperatorRights_grantedOnAddAndRevokedOnRemove() public {
        (, address tranche0,) = _createMarket("Floating");
        Underwriter underwriter = _deployUnderwriter();

        assertFalse(vault.isOperator(address(underwriter), tranche0), "no rights before registration");

        underwriter.addTranche(tranche0);
        assertTrue(vault.isOperator(address(underwriter), tranche0), "granted on registration");

        underwriter.removeTranche(tranche0);
        assertFalse(vault.isOperator(address(underwriter), tranche0), "revoked on removal");
    }

    // ── the full repay round trip cannot overshoot scaledDebt ────────────────

    function testFuzz_fullRepayRoundTripDoesNotOvershoot(uint256 scaled, uint256 idx) public pure {
        scaled = bound(scaled, 1, 1e36);
        idx = bound(idx, 1e27, 1e33);

        assertLe(scaled.rayMul(idx).rayDiv(idx), scaled, "round trip must not exceed scaledDebt");
    }

    /// The round trip above is only safe because the index never drops below 1e27, which in turn
    /// holds only while minimumMarketMultiplier is at or above 1e27.
    function test_floatingIndexNeverDropsBelowRay() public {
        MarketBundle memory bundle = _createReadyMarket("Floating");
        _fundTranche(bundle.tranche0Addr, makeAddr("senior"), 10_000e18);

        assertGe(irm.minimumMarketMultiplier(), 1e27, "multiplier floor keeps the index at or above RAY");
        assertGe(bundle.market.index(), 1e27, "index starts at RAY");

        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        assertGe(bundle.market.index(), 1e27, "index only grows");
    }
}
