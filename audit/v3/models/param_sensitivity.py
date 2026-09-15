#!/usr/bin/env python3
"""
param_sensitivity.py - every governance-settable parameter: the range the HEAD code permits vs the
range in which the system misbehaves; every overlap is listed with the number. HEAD a843c1d.

Permitted ranges are read from the setter / initializer named in each row. Unsafe values are
computed here with the exact arithmetic (capmath): checked overflow in calculateCompoundedInterest,
rayMul; lockedValue and maxLiquidatable denominators; healthiness vs unrecoverableDebt (I38 / P13);
premium vs principal; and the economic thresholds from the sibling models. Scale: debt up to $250M,
horizons up to 30 years. Bounds at HEAD that were missing in round 1: Registry.initialize now checks
lt <= 1e27, lt > buffer, targetHealth >= 1.25e27 (Registry.sol L106-107) - the round-1 "unvalidated
Registry defaults" overlap is CLOSED.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, DAY, HOUR, SECONDS_PER_YEAR, rayMul, rayDiv, compounded_interest, Revert,  # noqa: E402
                     ray_pow_ray, ray_ln, LN2_RAY, term_multiplier, locked_value, DEFAULTS)

ROWS = []


def row(param, where, permitted, unsafe, overlap):
    ROWS.append((param, where, permitted, unsafe, overlap))


def find_rate_revert(exp):
    lo, hi = RAY, 10**60
    for _ in range(300):
        mid = int(math.sqrt(lo * hi)) if hi // lo > 4 else (lo + hi) // 2
        try:
            compounded_interest(mid, exp)
            lo = mid
        except Revert:
            hi = mid
        if hi - lo <= 1:
            break
    return hi


def rate_to_unhealthy(seconds, growth=1.6):
    lo, hi = 0, 10**35
    for _ in range(200):
        mid = (lo + hi) // 2
        try:
            f = compounded_interest(mid, seconds)
        except Revert:
            hi = mid
            continue
        if f >= int(growth * RAY):
            hi = mid
        else:
            lo = mid
        if hi - lo <= 1:
            break
    return hi


def main():
    p = DEFAULTS
    b, lt = p["liquidationBonus"], p["lt"]
    lag2, lag10 = rayDiv(RAY, RAY + b), rayDiv(RAY, RAY + int(0.1e27))

    row("lt", "BaseMarket.setLt L89-96 (GUARDIAN); Registry.initialize L106", "buffer < lt <= 1e27",
        "lt > 1/(1+bonus): unrecoverableDebt>0 while healthiness>=1 (I38/P13) - %.4f at bonus 2%%, %.4f at bonus 10%%; "
        "lt <= ltv+buffer: every borrow reverts Unhealthy" % (lag2 / RAY, lag10 / RAY), "YES")

    # buffer: freeze all senior exits
    D, K = 50_000_000 * WAD, 100_000_000 * WAD
    buf_freeze = lt - rayDiv(D, K)
    row("buffer", "BaseMarket.setBuffer L79-86 (GUARDIAN)", "buffer < lt (may exceed lt - ltv; documented as tightening)",
        "buffer >= lt - D/K locks 100%% of every tranche's shares: %.2f at a full draw (D=0.5K); at 0.799 lockedValue = $%.0fB on $50M debt. "
        "A GUARDIAN can freeze all underwriter exits with one call." % (buf_freeze / RAY, locked_value(D, lt, int(0.799e27), [], 0) / WAD / 1e9), "YES")

    row("ltv", "BaseMarket.setLtv L71-76 (market OWNER)", "ltv + buffer <= lt", "none (0 disables borrowing)", "no")

    def first_frac(th, lt_, bon):
        den = th - rayMul(RAY + bon, lt_)
        return ((th - RAY) / RAY) / (den / RAY) if den > 0 else float("inf")
    th90 = None
    for th in range(125, 1000):
        if first_frac(th * RAY // 100, lt, b) >= 0.9:
            th90 = th / 100
            break
    worst_den = int(1.25e27) - rayMul(RAY + int(0.1e27), RAY)
    row("targetHealth", "BaseMarket.setTargetHealth L106-111 (GOVERNOR); Registry.initialize L107", ">= 1.25e27, NO upper bound",
        "perCleared = TH-(1+b)lt >= %.2f always (safe); first liquidation at h=1 clears %.0f%% of debt at TH 1.25, %.0f%% at 2, >= 90%% from TH %.2f "
        "(a full junior+senior wipe on a 1-wei breach)" % (worst_den / RAY, first_frac(int(1.25e27), lt, b) * 100, first_frac(2 * RAY, lt, b) * 100, th90),
        "YES (economic)")

    row("liquidationBonus", "IRM.setLiquidationBonus L174-184 (GOVERNOR); initialize", "0 <= bonus <= 0.1e27",
        "bonus 0: no liquidation is ever profitable (liquidation_cascade s2); bonus with lt > 1/(1+b): P13 band", "YES")

    row("averagingPeriod", "IRM.setAveragingPeriod L187-203 (GOVERNOR)", "[5 min, 1 day]",
        "whole band: a par deposit held one period depresses the fixed rate (ema_manipulation: break-even capital < 1x supply at every period)",
        "YES (economic)")

    of = {e: find_rate_revert(e) for e in (1, HOUR, DAY, SECONDS_PER_YEAR)}
    r1d, r1h, r12 = rate_to_unhealthy(DAY), rate_to_unhealthy(HOUR), rate_to_unhealthy(12)
    # binomial under-accrual vs exact
    err = []
    for rate in (1.0, 3.0, 10.0):
        for gap in (DAY, 30 * DAY, SECONDS_PER_YEAR):
            approx = compounded_interest(int(rate * RAY), gap) / RAY
            exact = math.exp(rate * gap / SECONDS_PER_YEAR)
            err.append((rate, gap, (approx - exact) / exact))
    worst = min(err, key=lambda e: e[2])
    row("base / slope0 / slope1", "IRM.setLiquiditySlopes L105-115 (GOVERNOR)", "UNBOUNDED (only kink <= 1e27)",
        "rate >= %.0f%%/yr makes a fully-drawn market (h 1.6) liquidatable within 1 day, %.0f%%/yr within 1 h, %.0f%%/yr in one 12 s block; "
        "calculateCompoundedInterest REVERTS above %.2e ray for a 1 h gap / %.2e (1 d) / %.2e (1 y): every _index() read on the IRM "
        "and every floating borrow/repay/liquidate bricks until slopes are lowered; below that the 3-term binomial UNDER-accrues by up to "
        "%.1f%% (rate %.0f%%/yr, gap %d d) - a borrower undercharge, not an error"
        % (r1d / RAY * 100, r1h / RAY * 100, r12 / RAY * 100, of[HOUR] / RAY, of[DAY] / RAY, of[SECONDS_PER_YEAR] / RAY,
           -worst[2] * 100, worst[0] * 100, worst[1] // DAY), "YES")

    row("kink", "IRM.setLiquiditySlopes L111", "kink <= 1e27 (0 handled)", "none", "no")

    # rayPowRay bound: exp <<= k unchecked in rayExp
    k_of = 256 - (RAY.bit_length())        # 166 -> x >= 166 ln2
    x_of = k_of * LN2_RAY
    G_of = math.exp(x_of / RAY / 2)        # multiplier 2 -> frac part... integer part handles most; state as growth factor
    row("marketMultiplier", "BaseMarket.setMarketMultiplier L137-152 (OWNER); band init-only IRM L84-87", "[1e27, 2e27] at deploy; band has NO setter",
        "none inside the band. rayExp `exp <<= k` is an UNCHECKED shift: silent wrap needs frac*ln(G) >= %.0f ray, i.e. a per-charge growth "
        "factor G >= e^%.0f - unreachable while the binomial reverts first" % (x_of / RAY, x_of / RAY), "no")

    rate = int(0.15e27)
    tu = rayDiv(DAY, 30 * DAY)
    need = SECONDS_PER_YEAR * RAY // (DAY * rate // RAY)
    slope_star = rayDiv(need - RAY, RAY - tu)
    row("termMultiplierSlope", "IRM.setTermMultiplierSlope L149-152 (GOVERNOR)", "UNBOUNDED",
        "multiplier = 1 + slope(1 - term/max) >= 1 always (never negative, never below the plain rate); slope >= %.0f ray makes a 1-day loan's "
        "premium >= its principal at 15%% (availableCredit(term) -> 0, borrow reverts InvalidPrincipal); rayMul overflow above %.1e ray"
        % (slope_star / RAY, (2**256 - 1 - RAY // 2) // rate / RAY), "YES (short-term DoS only)")

    # underwriter rate self-dealing timeline
    row("underwriterRate", "BaseMarket.setUnderwriterRate L130-134 (market OWNER = third party) -> IRM L124-131", "0 <= rate <= maximumUnderwriterRate (1e27 at deploy)",
        "0: underwriting negative-EV at any default risk (rate_sweep). 100%%: a fully-drawn market goes unhealthy from accrual in %.0f days and the "
        "owner-as-underwriter has received more cUSD than its collateral is worth after a further ln(1/lt)/rate = %.0f days (P14 economics); "
        "at 20%% those are %.0f and %.0f days" % (math.log(1.6) * 365, math.log(1 / 0.8) * 365, math.log(1.6) / 0.2 * 365, math.log(1 / 0.8) / 0.2 * 365),
        "YES")

    row("maximumUnderwriterRate", "IRM.initialize L88 (NO setter)", "any uint256 at init (1e27 in deploy)",
        "above 1e27 the self-dealing window shrinks as 1/rate; a bad init is permanent (no setter)", "YES (init only)")

    term_star = SECONDS_PER_YEAR * RAY // int(0.35e27)
    row("maximumTermLimit / minimumTermLimit", "FixedMarket.setTermLimits L59-61 (GOVERNOR)", "max != 0, min <= max, otherwise UNBOUNDED",
        "term > %.2f years: whole-term premium >= principal at 35%% carry (borrow of the limit yields ~0 principal); a long max term also locks "
        "a manipulated EMA rate for the whole term (ema_manipulation)" % (term_star / SECONDS_PER_YEAR), "YES (economic)")

    row("grace", "FixedMarket.initialize L55 (NO setter; Registry.createFixedMarket passes it)", "any uint256",
        "0: KEEPER extendAdmin rolls a loan the second it expires with NO health check (bypasses the Unhealthy guard on extend, L109); "
        "large: expired loans are never rolled and pay nothing - $%.0f/day of free credit per $10M at 30%% carry (liquidation_cascade s3)" % (10e6 * 0.3 / 365),
        "YES")

    row("fixedCreditLimit", "BaseMarket.setFixedCreditLimit L99-103 (GOVERNOR)", "UNBOUNDED (0 disables)", "none: creditLimit = min(fixed, variable)", "no")

    row("tranche weights", "BaseMarket.setTrancheWeights L119-127 (OWNER); _setTranches L390-406", "sum == 1e27; a weight may be 0; reverts if h < 1",
        "weight 0 = full junior-first slash exposure with no premium; the JUNIOR is 100%% locked (Tranche.unlockedSupply) from a %.0f%% draw "
        "(lockedValue = D/(lt-buffer) lands on it first)" % (0.05 * 0.7 / 0.5 * 100), "no (economic)")

    row("Registry lt / buffer / targetHealth", "Registry.initialize L106-107", "lt <= 1e27, lt > buffer, TH >= 1.25e27 (NEW at HEAD)",
        "round-1 overlap (unvalidated) CLOSED; same lt > 1/(1+b) band as setLt remains", "YES (same as lt)")

    row("VESTING_PERIOD / KILL_RATIO / MIN,MAX_AVERAGING", "constants (12 h / 100 / 5 min, 1 d)", "n/a", "not settable", "no")

    print("param_sensitivity.py  HEAD a843c1d - permitted vs unsafe ranges (numbers from exact arithmetic)\n")
    print("%-40s | %-58s | %s" % ("parameter", "permitted", "OVERLAP"))
    print("-" * 120)
    n = 0
    for param, where, permitted, unsafe, overlap in ROWS:
        print("%-40s | %-58s | %s" % (param, permitted[:58], overlap))
        print("   unsafe: %s" % unsafe)
        print("   setter: %s" % where)
        if overlap.upper().startswith("YES"):
            n += 1
    print("-" * 120)
    print("overlaps: %d of %d parameters" % (n, len(ROWS)))

    print("\n== numeric details ==")
    print("compoundedInterest revert: rate > %.3e ray (1 s gap), %.3e (1 h), %.3e (1 d), %.3e (1 y)" % tuple(of[e] / RAY for e in (1, HOUR, DAY, SECONDS_PER_YEAR)))
    print("rate to push h 1.6 -> 1.0: 1 day %.0f%%/yr, 1 hour %.0f%%/yr, 1 block %.0f%%/yr" % (r1d / RAY * 100, r1h / RAY * 100, r12 / RAY * 100))
    print("binomial vs exact e^(rt): " + "; ".join("r=%.0f%% gap %dd: %+.2f%%" % (r * 100, g // DAY, e * 100) for r, g, e in err))
    print("healthiness lag threshold: lt > %.4f (bonus 2%%), > %.4f (bonus 10%%)" % (lag2 / RAY, lag10 / RAY))
    print("maxLiquidatable perCleared at permitted extremes TH 1.25 / lt 1.0 / bonus 10%%: %.2f ray (> 0, as the planning note says)" % (worst_den / RAY))
    for th in (1.25, 1.5, 2.0, 3.0):
        print("  first liquidation at h=1: TH %.2f lt 0.8 bonus 2%%: %.0f%% of debt" % (th, min(100, first_frac(int(th * RAY), lt, b) * 100)))
    print("rayPowRay sanity: (1.1)^2 = %s, (1.1)^1.5 = %s (float 1.1^1.5 = %.12f)" % (
        ray_pow_ray(int(1.1e27), 2 * RAY) / RAY, ray_pow_ray(int(1.1e27), int(1.5e27)) / RAY, 1.1 ** 1.5))

    print("\n=== HEADLINE ===")
    print("%d of %d parameters have a permitted range overlapping an unsafe one. Accounting-breaking: lt in (%.4f, 1] at bonus 2%% (I38 fails: write-off" % (n, len(ROWS), lag2 / RAY))
    print("possible while liquidate reverts Healthy); unbounded slopes (>= %.0f%%/yr liquidates a full market within a day; > %.2e ray reverts the index" % (r1d / RAY * 100, of[HOUR] / RAY))
    print("and bricks every floating market); buffer >= %.2f freezes every tranche exit (GUARDIAN, one call); grace is init-only. Registry.initialize is now validated." % (buf_freeze / RAY))


if __name__ == "__main__":
    main()
