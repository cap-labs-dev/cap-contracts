#!/usr/bin/env python3
"""
param_sensitivity.py - H8: for every governance-settable parameter, the range the code's own
checks permit vs the range in which the system misbehaves. Every overlap is a finding.

"Permitted" is read from the setter (or initializer) in the contract named. "Unsafe" is computed
numerically here with the exact arithmetic (capmath): checked-overflow in
calculateCompoundedInterest / rayMul, division by zero or underflow in lockedValue and
maxLiquidatable, healthiness lagging unrecoverableDebt, premium exceeding principal, and the
economic thresholds established by the other models (rate_sweep, ema_manipulation,
solvency_waterfall). Numbers use realistic scale: cUSD supply up to $500M, debt up to $250M, time
horizons up to 30 years.

Columns: parameter | where set | permitted | unsafe region | OVERLAP
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, DAY, HOUR, SECONDS_PER_YEAR, rayMul, rayDiv, compounded_interest, Revert,
                     max_liquidatable, locked_value, term_multiplier, fixed_premium, principal_within,
                     next_liquidity_rate, DEFAULTS)  # noqa: E402

ROWS = []


def row(param, where, permitted, unsafe, overlap, note=""):
    ROWS.append((param, where, permitted, unsafe, overlap, note))


def find_rate_overflow(exp):
    """Smallest rate (ray) at which calculateCompoundedInterest reverts for elapsed `exp` seconds (bisection on log scale)."""
    lo, hi = RAY, 10**60
    for _ in range(200):
        mid = int((lo * hi) ** 0.5) if hi // lo > 4 else (lo + hi) // 2
        try:
            compounded_interest(mid, exp)
            lo = mid
        except Revert:
            hi = mid
        if hi - lo <= 1:
            break
    return hi


def find_debt_overflow(index):
    """Largest scaledDebt s.t. rayMul(scaled, index) does not revert."""
    return (2**256 - 1 - RAY // 2) // index


def main():
    p = DEFAULTS
    b = p["liquidationBonus"]

    # ---------------- lt ----------------
    lag_lt = rayDiv(RAY, RAY + b)  # 1/(1+bonus)
    row("lt", "BaseMarket.setLt", "buffer < lt <= 1e27 (lt < ltv allowed)",
        "lt > 1/(1+bonus) = %.4f: healthiness>=1 while unrecoverableDebt>0 (solvency_waterfall); "
        "lt <= ltv+buffer: every borrow reverts Unhealthy / instant liquidation" % (lag_lt / RAY), "YES",
        "Registry.initialize copies lt with NO check: lt=0 or lt<=buffer bricks lockedValue (div by zero) on every market created")

    # ---------------- ltv ----------------
    row("ltv", "BaseMarket.setLtv", "ltv + buffer <= lt", "none found (ltv=0 disables borrowing, safe)", "no")

    # ---------------- buffer ----------------
    # lockedValue = debt / (lt - buffer); lt - buffer tiny => locked value huge => all tranche shares locked
    lv = []
    debt = 50_000_000 * WAD
    for buf in (int(0.1e27), int(0.3e27), int(0.7e27), int(0.79e27), int(0.799e27), int(0.8e27) - 1):
        lv.append((buf, rayDiv(debt, p["lt"] - buf) / WAD / 1e6))
    row("buffer", "BaseMarket.setBuffer", "buffer < lt (may exceed lt - ltv, documented)",
        "buffer >= lt - ltv locks 100%% of tranche capital (lockedValue $%.0fM on $50M debt at buffer=0.3; $%.0fM at 0.799)" % (lv[1][1], lv[4][1]),
        "YES (documented as intended tightening)",
        "Registry.initialize: buffer >= lt => rayDiv(debt, 0) reverts in lockedValue -> Tranche.unlockedSupply/maxRedeem/claimable all revert")

    # ---------------- targetHealth ----------------
    # denominator targetHealth - (1+b)*lt ; permitted floor 1.25 vs max (1+b)*lt = 1.1*1.0
    worst_den = int(1.25e27) - rayMul(RAY + int(0.1e27), RAY)
    # first-liquidation size fraction (TH-1)/(TH-(1+b)lt)
    def first_frac(th, lt, bon):
        den = th - rayMul(RAY + bon, lt)
        return ((th - RAY) / RAY) / (den / RAY) if den > 0 else float("inf")
    ff = [(th / RAY, first_frac(th, p["lt"], b) * 100) for th in (int(1.25e27), int(1.5e27), int(2e27), int(5e27))]
    # overflow: rayMul(targetHealth, debt) with debt 250M
    th_of = (2**256 - 1 - RAY // 2) // (250_000_000 * WAD)
    row("targetHealth", "BaseMarket.setTargetHealth", ">= 1.25e27, NO upper bound",
        "maxLiquidatable denominator min = %.2f ray (safe); first liquidation at h=1 clears %s of debt; rayMul overflow at TH > %.1e ray (absurd)"
        % (worst_den / RAY, ", ".join("%.0f%%@TH%.2f" % (f, t) for t, f in ff), th_of / RAY),
        "YES (economic)",
        "Registry.initialize: NO 1.25 floor. TH < (1+bonus)*lt => maxLiquidatable underflows => liquidate() reverts => no liquidation possible at all")

    # ---------------- liquidationBonus ----------------
    row("liquidationBonus", "IRM.setLiquidationBonus / initialize", "0 <= bonus <= 0.1e27",
        "bonus = 0: liquidation never profitable (liquidation_cascade); bonus > 1/lt - 1 = %.2f%% at lt 0.8: never; "
        "(1+bonus)*lt > 1 with lt > %.4f: health lags" % ((1 / 0.8 - 1) * 100, lag_lt / RAY), "YES",
        "0 is permitted; combined with lt in (0.9804, 1] the pair is permitted and unsafe")

    # ---------------- base / slope0 / slope1 ----------------
    of_1y = find_rate_overflow(SECONDS_PER_YEAR)
    of_30y = find_rate_overflow(30 * SECONDS_PER_YEAR)
    of_1s = find_rate_overflow(1)
    # rate at which a market drawn to ltv reaches lt within 1 day / 1 hour (h: 1.6 -> 1.0 = 60% growth)
    def rate_to_unhealthy(seconds):
        lo, hi = 0, 10**35
        for _ in range(200):
            mid = (lo + hi) // 2
            try:
                f = compounded_interest(mid, seconds)
            except Revert:
                hi = mid
                continue
            if f >= int(1.6e27):
                hi = mid
            else:
                lo = mid
            if hi - lo <= 1:
                break
        return hi
    r_1d = rate_to_unhealthy(DAY)
    r_1h = rate_to_unhealthy(HOUR)
    r_1b = rate_to_unhealthy(12)
    # index-driven totalDebt overflow: scaledDebt*index; with index after 1y at rate X
    row("base / slope0 / slope1", "IRM.setLiquiditySlopes", "UNBOUNDED (only kink <= 1e27 checked)",
        "rate >= %.0f%%/yr pushes a fully-drawn market (h=1.6) unhealthy within 1 day, >= %.0f%%/yr within 1 hour, "
        ">= %.0f%%/yr within one 12s block; calculateCompoundedInterest reverts at rate > %.2e ray (1y gap) / %.2e ray (1s gap)"
        % (r_1d / RAY * 100, r_1h / RAY * 100, r_1b / RAY * 100, of_1y / RAY, of_1s / RAY),
        "YES",
        "a rate above the revert point bricks _index() -> every borrow/repay/liquidate on floating markets reverts until slopes are lowered")

    # ---------------- kink ----------------
    row("kink", "IRM.setLiquiditySlopes", "kink <= 1e27 (0 allowed, handled)", "none found", "no")

    # ---------------- termMultiplierSlope ----------------
    # premium at min term (1d of 30d): multiplier 1 + slope*(29/30); premium >= principal when
    # term*rate*mult/year >= 1 -> mult >= year/(term*rate)
    rate = int(0.15e27)
    tu = rayDiv(DAY, 30 * DAY)
    need_mult = SECONDS_PER_YEAR * RAY // (DAY * rate // RAY)  # ray
    slope_star = rayDiv(need_mult - RAY, RAY - tu)
    # overflow in rayMul(projected, termMultiplier)
    tm_of = (2**256 - 1 - RAY // 2) // rate
    row("termMultiplierSlope", "IRM.setTermMultiplierSlope", "UNBOUNDED",
        "slope >= %.0f ray: a 1-day loan's premium >= its principal at 15%% rate (availableCredit(term) -> ~0, borrow reverts InvalidPrincipal); "
        "rayMul overflow at slope > %.1e ray" % (slope_star / RAY, tm_of / RAY),
        "YES (grief/DoS of short terms only)")

    # ---------------- underwriterRate ----------------
    row("underwriterRate", "BaseMarket.setUnderwriterRate (MARKET OWNER) -> IRM.updateUnderwriterRate",
        "0 <= rate <= maximumUnderwriterRate (init-only, 1e27 in deploy)",
        "rate < (1+bonus)*p_default: underwriting negative EV (rate_sweep: 2.04% at 2% default risk); 0 is legal and documented",
        "YES (economic)", "set by the borrowing side, not by governance or the underwriters")

    # ---------------- marketMultiplier ----------------
    row("marketMultiplier", "BaseMarket.setMarketMultiplier (OWNER) -> IRM.updateMarketMultiplier",
        "[minimumMarketMultiplier, maximumMarketMultiplier] init-only ([1e27, 2e27] in deploy)",
        "none within the deploy band; band itself has NO setter so a bad init is permanent", "no")

    # ---------------- averagingPeriod ----------------
    row("averagingPeriod", "IRM.setAveragingPeriod (falls to ADMIN, H9)", "[5 min, 1 day]",
        "entire band: EMA depression is profitable at every period for L >= $10M (ema_manipulation)", "YES (economic)")

    # ---------------- tranche weights ----------------
    row("tranche weights", "BaseMarket.setTrancheWeights / setTranches / Registry.createTranche",
        "sum == 1e27; individual weight unbounded incl. 0; reverts if healthiness < 1",
        "weight 0 on a tranche = no premium but full slash exposure (junior-first) - accepted by code; "
        "clamp keeps rayMul half-up rounding from underflowing", "no (economic only)")

    # ---------------- fixedCreditLimit ----------------
    row("fixedCreditLimit", "BaseMarket.setFixedCreditLimit", "UNBOUNDED (0 disables borrowing)",
        "none: creditLimit = min(fixed, variable) so variable always binds", "no")

    # ---------------- term limits ----------------
    # chargeableDebt * term overflow: debt 250M * term
    term_of = (2**256 - 1) // (250_000_000 * WAD)
    # premium > principal for max term at 15%+20% carry: term > year/0.35
    term_gt_principal = SECONDS_PER_YEAR * RAY // int(0.35e27)
    row("maximumTermLimit / minimumTermLimit", "FixedMarket.setTermLimits", "max != 0, min <= max, otherwise UNBOUNDED",
        "term > %.1f years: whole-term premium >= principal at 35%% carry (borrow of the limit yields ~0 principal); "
        "term*debt overflow at term > %.1e s (absurd). Long max terms also lock a manipulated EMA rate for the whole term"
        % (term_gt_principal / SECONDS_PER_YEAR, term_of), "YES (economic)")

    # ---------------- grace ----------------
    row("grace", "FixedMarket.initialize (NO setter)", "UNBOUNDED, init-only",
        "grace = 0: KEEPER may extendAdmin (skips health check, adds arrears premium) the instant a loan expires (H3)", "YES (economic)")

    # ---------------- vesting period ----------------
    row("vestingPeriod", "Tranche.setVestingPeriod (owner)", "> 0, UNBOUNDED",
        "1 second: premium vests instantly -> deposit-before-notifyPremium / claim / requestRedeem sandwich; "
        "very large: premium effectively never vests (locked in tranche)", "YES")

    # ---------------- init-only IRM band ----------------
    row("minimum/maximumMarketMultiplier, maximumUnderwriterRate", "IRM.initialize (NO setter)",
        "min <= max checked; otherwise UNBOUNDED", "maximumUnderwriterRate huge => owner can set 1000%/yr underwriter rate: "
        "premium minted to tranches outpaces reserve (reserve_decay); no way to repair without upgrade", "YES")

    # ---------------- Registry defaults ----------------
    row("Registry lt/buffer/targetHealth", "Registry.initialize (NO setter, NO validation)",
        "ANY uint256", "lt <= buffer: lockedValue reverts (tranche exits bricked); targetHealth < (1+b)*lt: maxLiquidatable reverts; "
        "lt > 1e27: over-collateral credit. BaseMarket copies them unchecked at market creation", "YES")

    # ---------------- print table ----------------
    print("param_sensitivity.py - permitted vs unsafe ranges (exact arithmetic where a number is given)\n")
    print("%-42s | %-70s | %-12s" % ("parameter (where)", "permitted", "OVERLAP"))
    print("-" * 130)
    n_yes = 0
    for param, where, permitted, unsafe, overlap, note in ROWS:
        print("%-42s | %-70s | %s" % (param, permitted[:70], overlap))
        print("   unsafe: %s" % unsafe)
        if note:
            print("   note:   %s" % note)
        print("   setter: %s" % where)
        if overlap.upper().startswith("YES"):
            n_yes += 1
    print("-" * 130)
    print("overlaps: %d of %d parameters" % (n_yes, len(ROWS)))

    print("\n== numeric details ==")
    print("compoundedInterest revert thresholds: rate > %.3e ray (%.1e %%/yr) for a 1y gap; > %.3e ray for 30y; > %.3e ray for 1s" % (
        of_1y / RAY, of_1y / RAY * 100, of_30y / RAY, of_1s / RAY))
    print("rate to push h=1.6 -> 1.0: 1 day %.0f%%/yr, 1 hour %.0f%%/yr, 1 block %.0f%%/yr" % (r_1d / RAY * 100, r_1h / RAY * 100, r_1b / RAY * 100))
    print("maxLiquidatable perCleared at permitted extremes: TH 1.25, lt 1.0, bonus 10%%: %.2f ray (>0, safe by 0.15 as the NatSpec says)" % (worst_den / RAY))
    print("healthiness lag threshold: lt > %.4f at bonus 2%%; at bonus 10%%: lt > %.4f" % (lag_lt / RAY, rayDiv(RAY, RAY + int(0.1e27)) / RAY))
    print("termMultiplierSlope making 1-day loans cost >= principal at 15%% rate: %.0f ray" % (slope_star / RAY))
    for th in (int(1.25e27), int(1.5e27), int(2e27)):
        for lt in (int(0.8e27), int(0.95e27), RAY):
            print("  first liquidation at h=1: TH %.2f lt %.2f bonus 2%%: %.0f%% of debt" % (th / RAY, lt / RAY, min(100, first_frac(th, lt, b) * 100)))

    print("\n=== HEADLINE ===")
    print("%d of %d governance parameters have a permitted range that overlaps an unsafe one. The three that break" % (n_yes, len(ROWS)))
    print("accounting (not just economics): lt in (%.4f, 1] with bonus 2%% (health lags unrecoverable debt); unbounded slopes" % (lag_lt / RAY))
    print("(>= %.0f%%/yr renders a full market liquidatable within a day; >%.1e ray reverts the index); and Registry.initialize" % (r_1d / RAY * 100, of_1y / RAY))
    print("accepting lt/buffer/targetHealth with no validation (lt<=buffer or TH<(1+b)lt bricks exits/liquidations on every market).")


if __name__ == "__main__":
    main()
