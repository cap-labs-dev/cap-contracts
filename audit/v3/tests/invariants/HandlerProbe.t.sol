// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapInvariants } from "./Cap.invariants.t.sol";
import { CapHandler } from "./CapHandler.sol";
import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

/// @dev Smoke test: a scripted path through the handler, printing the ghosts so a reviewer can
/// see the guarded actions actually fire (borrow, liquidate, write-off, queue, underwriter).
/// Composes the invariant world rather than inheriting it so the campaign is not run twice.
contract HandlerProbe is Test {
    function test_probe_handlerReachesEveryRegime() public {
        CapInvariants w = new CapInvariants();
        w.setUp();
        CapHandler h = w.handler();

        // NB handler bounds are modular: _bound(x, lo, hi) = lo + x % (hi - lo + 1), so the
        // arguments below are chosen to fold onto the intended values.
        h.stableDeposit(1, 500_000e6);
        h.floatBorrow(w.floating().availableCredit() - 1); // folds to the full credit line
        h.fixedBorrow(w.fixedM().availableCredit(7 days) - 1, 6 days); // folds to (full, 7 days)
        h.warp(10 days);
        h.floatCharge();
        h.uwDeposit(2, 100e18);
        h.uwAllocate(1, 50e18);
        h.uwDeallocateAsync(0, 10e18);
        h.uwFinalize(0, 5e18);
        h.uwReport(0);
        h.vaultRequestRedeem(0, 0, 10e18);
        h.vaultClaimFifo(0, 0, 1e18);
        h.stableRequestRedeem(0, 100e18);
        h.stableTransferRequest(0, 1);
        h.stableClaim(0, 50e18);
        h.stableClaimFifo(1, 10e18);
        h.movePrice(0); // folds to 5000 bps: collateral halves -> debt == capital, unhealthy
        h.floatWriteOff(); // unrecoverable = debt - capital/(1+bonus) > 0
        h.fixedWriteOff(0);
        h.floatLiquidate(type(uint256).max); // still unhealthy after write-off: slash
        h.fixedLiquidate(0, type(uint256).max);
        h.coverBadDebt(1e18);
        h.stableRoundTrip(2, 1_000e6);
        h.setLt(0, 1 + ((0.99e27 - 0.1e27 - 1) << 2)); // odd -> full band, folds to lt = 0.99e27
        h.setLiquidationBonus(1 + (0.1e27 << 2)); // odd -> full band, folds to 0.1e27

        console2.log("calls               ", h.calls());
        console2.log("reverts             ", h.ghost_reverts());
        console2.log("slashCount          ", h.ghost_slashCount());
        console2.log("badDebtRecognized   ", h.ghost_badDebtRecognized());
        console2.log("badDebtCovered      ", h.ghost_badDebtCovered());
        console2.log("badDebtRetired      ", h.ghost_badDebtRetiredOnRedeem());
        console2.log("badDebt (live)      ", w.stable().badDebt());
        console2.log("floating totalDebt  ", w.floating().totalDebt());
        console2.log("fixed totalDebt     ", w.fixedM().totalDebt());
        console2.log("creditBackedSupply  ", w.stable().creditBackedSupply());
        console2.log("stable requests     ", h.requestCount(address(w.stable())));
        console2.log("senior requests     ", h.requestCount(address(w.senior())));
        console2.log("uw requests         ", h.uwRequestCount());
        console2.log("uw totalAssets      ", w.uw().totalAssets());
        console2.log("uw totalDebt(book)  ", w.uw().totalDebt());
        console2.log("floating lt         ", w.floating().lt());
        console2.log("liquidationBonus    ", w.rateModel().liquidationBonus());
        console2.log("ltSets / bonusSets  ", h.ghost_ltSets(), h.ghost_bonusSets());
        console2.log("roundTripExcess     ", h.ghost_roundTripExcess());
        console2.log("priceDropNoSlash    ", h.ghost_priceDropWithoutSlash());

        // the invariant bodies in the stressed regime (I38 is deliberately violated by setLt/setLiquidationBonus above)
        w.invariant_I1_reserveCoversUnlockedSupply();
        w.invariant_I2_supplyDecomposition();
        w.invariant_I3_debtMatchesCreditBackedSupply();
        w.invariant_I4_badDebtAccounting();
        w.invariant_I5_coverageOrRemedy();
        w.invariant_I13_queueConservation();
        w.invariant_I15_fifo();
        w.invariant_I17_queueAccounting();
        w.invariant_I18_stakedEqualsOptedIn();
        w.invariant_I19_vestingBounded();
        w.invariant_I30_masterSolvency();
        w.invariant_I33_controllerSetConsistency();
        w.invariant_I34_stableHoldsQueueAndPot();
        w.invariant_I35_creditPlusBadDebtWithinSupply();
        w.invariant_I37_underwriterBookNotBelowLive();
        console2.log("I30 coverage (ray)  ", w.ghost_i30_minCoverageRay());

        // I38 finding, stated deterministically: guardian lt = 0.99 and governor bonus = 0.10 are
        // both accepted, yet a liquidation then releases 1.089 of collateral per unit of debt at
        // the threshold, i.e. more than the position is worth
        uint256 perDebt = w.floating().lt() * (1e27 + w.rateModel().liquidationBonus()) / 1e27;
        console2.log("I38 lt*(1+bonus)    ", perDebt);
        assertGt(perDebt, 1e27, "I38 is expected to be violated by permitted parameters");
    }
}
