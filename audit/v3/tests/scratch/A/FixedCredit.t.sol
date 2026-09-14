// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title FixedCredit — WS-A I32 on the REAL FixedMarket: principal <= availableCredit(term) => borrow
/// succeeds, health >= 1, totalDebt <= creditLimit; split-invariance of the premium; worked example.
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/A forge test --match-path 'audit/v3/tests/scratch/A/FixedCredit.t.sol' -vv --fuzz-runs 2000
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { MathUtils } from "../../../../../contracts/utils/MathUtils.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract FixedCredit is CapDeployer {
    using WadRayMath for uint256;

    FixedMarket market;
    Tranche tranche0;
    Tranche tranche1;
    address supplier = makeAddr("supplier");
    address lp = makeAddr("lp");

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true; // base 5%, slope0 5%, slope1 10%, kink 80%
        cfg.defaultMaximumTermLimit = 365 days;
        cfg.defaultMinimumTermLimit = 1 days;
        _deployCapWithConfig(cfg);
        (address m, address t0, address t1) = _createFixedMarket("fx");
        market = FixedMarket(m);
        tranche0 = Tranche(t0);
        tranche1 = Tranche(t1);
        _configureMarketRates(FloatingMarket(m)); // slopes + 20% underwriter rate
        irm.setTermMultiplierSlope(0.5e27); // short terms pay up to 1.5x the liquidity rate
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(address(tranche0), supplier, 1_000_000e18);
        _fundTranche(address(tranche1), makeAddr("junior"), 50_000e18);
        _depositStable(lp, 400_000e18); // reserve so utilization moves with each mint
    }

    // ───────────────────────── I32 ─────────────────────────

    /// For any term and any principal <= availableCredit(term): borrow succeeds, health >= 1e27,
    /// totalDebt <= creditLimit (to the wei), and the charged premium is <= the one priced in.
    function testFuzz_I32_principalWithinCredit(uint256 term, uint256 frac, uint256 mult, uint256 preBorrow) public {
        term = bound(term, 1 days, 365 days);
        mult = bound(mult, 1e27, 2e27);
        market.setMarketMultiplier(mult);
        // optionally put some unabsorbed credit into the window first (a prior same-window draw)
        preBorrow = bound(preBorrow, 0, 100_000e18);
        if (preBorrow > 0) {
            vm.prank(defaultBorrower);
            market.borrow(defaultBorrower, preBorrow, term);
        }
        uint256 credit = market.availableCredit(term);
        vm.assume(credit > 0);
        frac = bound(frac, 1, 1e18);
        uint256 principal = credit * frac / 1e18;
        vm.assume(principal > 0);
        uint256 limit = market.creditLimit();
        uint256 debtBefore = market.totalDebt();
        (uint256 liqQ, uint256 uwQ) = market.premiumForBorrow(principal, term);

        vm.prank(defaultBorrower);
        (uint256 id, uint256 actual) = market.borrow(defaultBorrower, principal, term);
        assertEq(actual, principal, "principal clipped");
        uint256 debtAfter = market.totalDebt();
        // I32 as stated (<= limit) is REFUTED by 1 wei when prior unabsorbed credit exists (see
        // test_I32_overshootByOneWei); the bound that holds is limit + 2.
        assertLe(debtAfter, limit + 2, "totalDebt > creditLimit + 2");
        if (preBorrow == 0) assertLe(debtAfter, limit, "totalDebt > creditLimit with no prior credit");
        assertGe(market.healthiness(), 1e27, "unhealthy after in-limit borrow");
        assertEq(debtAfter - debtBefore, principal + liqQ + uwQ, "premium charged != premiumForBorrow quote");
        assertEq(market.debt(id), principal + liqQ + uwQ);
    }

    /// The full draw (principal = availableCredit(term)) lands inside the limit even with the catch-up
    /// on prior unabsorbed credit and the multiplier at its maximum.
    function testFuzz_I32_fullDraw(uint256 term, uint256 preBorrow, uint256 dt) public {
        term = bound(term, 1 days, 365 days);
        market.setMarketMultiplier(2e27);
        preBorrow = bound(preBorrow, 0, 200_000e18);
        if (preBorrow > 0) {
            vm.prank(defaultBorrower);
            market.borrow(defaultBorrower, preBorrow, term);
            vm.warp(block.timestamp + bound(dt, 0, 2 hours)); // partial absorption into the average
        }
        uint256 credit = market.availableCredit(term);
        vm.assume(credit > 0);
        uint256 limit = market.creditLimit();
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max, term);
        assertLe(market.totalDebt(), limit + 2, "full draw overshoots creditLimit by more than 2 wei");
        assertGe(market.healthiness(), 1e27);
    }

    /// Split-invariance: drawing P in one call or as P1 + P2 in the same block charges the same total
    /// premium to the wei, up to the per-call floor (<= 2 wei).
    function testFuzz_splitInvariance(uint256 term, uint256 p, uint256 cut) public {
        term = bound(term, 1 days, 365 days);
        p = bound(p, 2e18, 100_000e18);
        cut = bound(cut, 1e18, p - 1e18);
        uint256 snap = vm.snapshotState();
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, p, term);
        uint256 single = market.debt(id) - p;
        vm.revertToState(snap);
        vm.startPrank(defaultBorrower);
        (uint256 idA,) = market.borrow(defaultBorrower, cut, term);
        (uint256 idB,) = market.borrow(defaultBorrower, p - cut, term);
        vm.stopPrank();
        uint256 split = market.debt(idA) - cut + market.debt(idB) - (p - cut);
        assertLe(split, single + 2, "split pays more");
        assertLe(single, split + 2, "split pays less");
    }

    /// Deterministic replay of the fuzz counterexample: a same-block prior draw of 100,000 cUSD, then a
    /// full draw. The catch-up is floored in availableCredit (L202) while the real charge is a difference
    /// of two floored premiums (L344-350), which can be one wei larger => totalDebt = creditLimit + 1.
    function test_I32_overshootByOneWei() public {
        uint256 term = 12747; // bound(12747, 1 days, 365 days)
        term = bound(term, 1 days, 365 days);
        market.setMarketMultiplier(2e27);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100_000e18, term);
        uint256 limit = market.creditLimit();
        uint256 credit = market.availableCredit(term);
        uint256 prior = irm.unsmoothedCredit();
        (uint256 liqQ, uint256 uwQ) = market.premiumForBorrow(credit, term);
        emit log_named_uint("term", term);
        emit log_named_uint("prior unabsorbed credit", prior);
        emit log_named_uint("creditLimit", limit);
        emit log_named_uint("totalDebt before", market.totalDebt());
        emit log_named_uint("availableCredit(term)", credit);
        emit log_named_uint("quoted liq premium", liqQ);
        emit log_named_uint("quoted uw premium", uwQ);
        emit log_named_uint("principal + quoted premium + debt before", market.totalDebt() + credit + liqQ + uwQ);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max, term);
        emit log_named_uint("totalDebt after", market.totalDebt());
        assertEq(market.totalDebt(), limit + 1, "reproduces: creditLimit + 1");
        assertEq(market.availableCredit(), 0);
    }

    /// Same state with ltv == lt and buffer == 0 (creditLimit == threshold): whenever the sizing overshoots
    /// by one wei, healthiness() < 1e27 and the max borrow REVERTS Unhealthy even though
    /// principal == availableCredit(term). The overshoot is data-dependent, so scan terms and require at
    /// least one reverting instance; every reverting instance succeeds with principal - 1.
    function test_I32_overshootRevertsAtLtvEqualsLt() public {
        market.setBuffer(0);
        market.setLtv(capConfig.defaultLt);
        market.setMarketMultiplier(2e27);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100_000e18, 30 days);
        uint256 limit = market.creditLimit();
        assertEq(limit, market.debtLiquidationThreshold(), "limit == threshold precondition");
        uint256 reverting;
        uint256 firstTerm;
        for (uint256 term = 1 days; term <= 365 days; term += 6 hours + 1) {
            uint256 snap = vm.snapshotState();
            uint256 credit = market.availableCredit(term);
            vm.prank(defaultBorrower);
            try market.borrow(defaultBorrower, credit, term) {
                assertLe(market.totalDebt(), limit, "succeeded but over the limit");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IBaseMarket.Unhealthy.selector, "unexpected revert");
                if (reverting == 0) firstTerm = term;
                reverting++;
                vm.revertToState(snap);
                snap = vm.snapshotState();
                vm.prank(defaultBorrower);
                market.borrow(defaultBorrower, credit - 1, term); // one wei less goes through
                assertLe(market.totalDebt(), limit);
            }
            vm.revertToState(snap);
        }
        uint256 scanned = (uint256(365 days) - uint256(1 days)) / (uint256(6 hours) + 1) + 1;
        emit log_named_uint("terms scanned", scanned);
        emit log_named_uint("terms where borrow(availableCredit(term)) reverts Unhealthy", reverting);
        emit log_named_uint("first such term (s)", firstTerm);
        assertGt(reverting, 0, "no reverting instance found");
    }

    // ───────────────────────── worked example for A.md ─────────────────────────

    function test_workedExample() public {
        uint256 term = 30 days;
        market.setMarketMultiplier(1.5e27);
        uint256 credit = market.availableCredit(term);
        uint256 limit = market.creditLimit();
        (uint256 liqRate, uint256 uwRate) = irm.fixedRatesAfterMint(address(market), term.rayDiv(365 days), limit);
        emit log_named_uint("creditLimit", limit);
        emit log_named_uint("availableCredit(30d)", credit);
        emit log_named_uint("liq rate after minting the whole limit (pre-multiplier)", liqRate);
        emit log_named_uint("uw rate", uwRate);
        (uint256 lq, uint256 uq) = market.premiumForBorrow(credit, term);
        emit log_named_uint("premiumForBorrow.liq", lq);
        emit log_named_uint("premiumForBorrow.uw", uq);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, credit, term);
        emit log_named_uint("debt[id]", market.debt(id));
        emit log_named_uint("totalDebt", market.totalDebt());
        emit log_named_uint("slack = creditLimit - totalDebt", limit - market.totalDebt());
        emit log_named_uint("healthiness", market.healthiness());
        // second draw in the same block: catch-up on the first draw's notional
        uint256 credit2 = market.availableCredit(term);
        emit log_named_uint("availableCredit(30d) after full draw", credit2);
    }

    /// ltv == lt, buffer == 0: creditLimit == threshold when active == total capital. Does a full
    /// draw plus premium ever land health below one by rounding? (If so, borrow reverts Unhealthy.)
    function testFuzz_fullDrawAtLtvEqualsLt(uint256 term, uint256 mult) public {
        term = bound(term, 1 days, 365 days);
        mult = bound(mult, 1e27, 2e27);
        market.setBuffer(0);
        market.setLtv(capConfig.defaultLt); // == lt
        market.setMarketMultiplier(mult);
        uint256 limit = market.creditLimit();
        assertEq(limit, market.debtLiquidationThreshold(), "limit == threshold precondition");
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max, term);
        assertLe(market.totalDebt(), limit);
        assertGe(market.healthiness(), 1e27);
    }
}
