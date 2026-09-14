#!/usr/bin/env python3
"""
liquidation_cascade.py - price path -> liquidation -> collateral sale impact -> further liquidation.
Does the system clear or spiral, and at what (impact k, liquidator latency L, bonus, lt)? HEAD a843c1d.

Exact pieces (capmath): healthiness, maxLiquidatable (incl. the recoverableDebt cap), the _liquidate
waterfall through Tranche.slash (junior first, clamp, floor-to-zero), unrecoverableDebt, hourly
debt accrual via MathUtils.calculateCompoundedInterest at the floating carry - premium keeps
accruing on unhealthy debt (P9): nothing in FloatingMarket._chargePremium checks health.

Scenario: K0 = $100M of one collateral (P0 $2000), 95/5 tranches, full draw D = $50M (ltv 0.5),
carry 30%/yr (harness curve at u=80% + 20% underwriter; multiplier 1). Exogenous path: price falls
x = 1.5%/h for 48 h (d = 51.6%: h<1 at hour 32 for lt 0.8, hour 22 for lt 0.7, hour 39 for lt 0.9;
the 49% insolvency point without any liquidation is hour 45), then flat. Market impact: the liquidator
sells the slashed collateral into a linear book: selling $V moves the price by k * V / $1M
(k in %); a PERM fraction of that stays in the oracle price (default 1.0 = all of it; 0.5 shown).
Liquidator: one LIQUIDATOR-role actor, checks every L hours; when h < 1 it takes maxLiquidatable
in CLIPS sized so that the clip's own average impact stays below the bonus (profitable clip:
V <= 2M * b / ((1+b) k)); up to 50 clips per check; a clip that is not profitable is not taken.
Outcome: "clears" if the debt is fully repaid or health >= 1 with unrecoverableDebt == 0 at the
end of 7 days; "spiral" if unrecoverableDebt > 0 at any point (cUSD holders lose).

Fixed-market section (P7): FixedMarket.extend (L109) reverts Unhealthy for EVERY borrower once
the market is unhealthy; only KEEPER extendAdmin (L113-124, after `grace`) rolls a loan, adding
arrears premium (_rollFromNow L318). Expiry itself is not enforced: an expired loan pays NOTHING
until someone rolls it. Days-to-unhealthy from accrual alone are computed per roll (term 30 d).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, HOUR, DAY, SECONDS_PER_YEAR, rayMul, rayDiv, healthiness, max_liquidatable,  # noqa: E402
                     unrecoverable_debt, liquidate, compounded_interest, TrancheState, DEFAULTS)

K0 = 100_000_000 * WAD
P0 = 2000 * WAD
CARRY = int(0.30e27)
X = 0.015
FALL_H = 48
HORIZON = 7 * 24
MAX_CLIPS = 50


def simulate(k, L, bonus, lt, perm=1.0, x=X, th=None):
    th = th or DEFAULTS["targetHealth"]
    tr = [TrancheState(K0 * 95 // 100 * WAD // P0, P0), TrancheState(K0 * 5 // 100 * WAD // P0, P0)]
    debt = rayMul(K0, DEFAULTS["ltv"])
    f = compounded_interest(CARRY, HOUR)
    impact_mult, cum_sold, n_clips, max_unrec, unbacked = 1.0, 0, 0, 0, 0
    clip_cap = (2e6 * (bonus / RAY) / ((1 + bonus / RAY) * (k / 100))) if k > 0 else 1e30   # $ per profitable clip
    for t in range(1, HORIZON + 1):
        before = debt
        debt = rayMul(debt, f)
        price = int(P0 * (1 - x) ** min(t, FALL_H) * impact_mult)
        for tt in tr:
            tt.price = price
        K = sum(tt.total_capital() for tt in tr)
        if unrecoverable_debt(K, debt, bonus) > 0:
            unbacked += debt - before          # premium minted while already insolvent (P9)
        if t % L == 0:
            for _ in range(MAX_CLIPS):
                h = healthiness(K, debt, lt)
                if h >= RAY or debt == 0:
                    break
                liq = max_liquidatable(K, debt, lt, th, bonus)
                clip = min(liq, int(clip_cap / (1 + bonus / RAY) * WAD))
                if clip < WAD:            # sub-dollar dust: nothing left to clear
                    break
                slashed, _ = liquidate(tr, clip, bonus)
                V = sum(slashed)
                debt -= clip
                n_clips += 1
                cum_sold += V
                impact_mult *= max(0.0, 1 - perm * (k / 100) * (V / WAD / 1e6))
                price = int(P0 * (1 - x) ** min(t, FALL_H) * impact_mult)
                for tt in tr:
                    tt.price = price
                K = sum(tt.total_capital() for tt in tr)
        max_unrec = max(max_unrec, unrecoverable_debt(K, debt, bonus))
    K = sum(tt.total_capital() for tt in tr)
    return dict(unrec=max_unrec, clips=n_clips, sold=cum_sold, debt=debt, h=healthiness(K, debt, lt),
                impact=1 - impact_mult, unbacked=unbacked, killed=[tt.killed for tt in tr])


def crit_k(L, bonus, lt, perm=1.0):
    lo, hi = 0.0, 5.0
    if simulate(hi, L, bonus, lt, perm)["unrec"] == 0:
        return None
    for _ in range(16):
        mid = (lo + hi) / 2
        if simulate(mid, L, bonus, lt, perm)["unrec"] > 0:
            hi = mid
        else:
            lo = mid
    return hi


def main():
    p = DEFAULTS
    b, lt = p["liquidationBonus"], p["lt"]
    print("liquidation_cascade.py  HEAD a843c1d  K0=$100M, D=$50M, carry 30%, path -1.5%/h x 48h, 7d horizon, PERM 1.0\n")
    print("== 1. Impact k (% per $1M sold) x liquidator latency L, defaults (bonus 2%, lt 0.8, TH 1.25) ==")
    print("  k %/$1M | L   | clips | collateral sold | oracle impact | end debt | end health | max unrec (cUSD loss) | unbacked premium minted | outcome")
    for k in (0.0, 0.1, 0.25, 0.5, 1.0, 2.0):
        for L in (1, 6, 24):
            r = simulate(k, L, b, lt)
            print("   %4.2f   | %2dh |  %3d  |    $%6.1fM     |    %5.1f%%     | $%5.1fM  |   %6.3f   |       $%6.2fM         |        $%7.0f          | %s" % (
                k, L, r["clips"], r["sold"] / WAD / 1e6, r["impact"] * 100, r["debt"] / WAD / 1e6, r["h"] / RAY,
                r["unrec"] / WAD / 1e6, r["unbacked"] / WAD, "SPIRAL" if r["unrec"] else ("cleared" if r["h"] >= RAY else "stalled")))

    print("\n== 2. Critical k* (smallest impact at which cUSD holders lose) by L x bonus x lt ==")
    print("  bonus | lt   | cushion 1-(1+b)lt |  L=1h   |  L=6h   |  L=24h  | (PERM 0.5: L=1h)")
    for bonus in (int(0.02e27), int(0.05e27), int(0.10e27)):
        for lt_ in (int(0.7e27), int(0.8e27), int(0.9e27)):
            row = []
            for L in (1, 6, 24):
                c = crit_k(L, bonus, lt_)
                row.append("%5.2f" % c if c is not None else " none")
            c5 = crit_k(1, bonus, lt_, perm=0.5)
            print("  %3.0f%%  | %.2f |      %5.1f%%       | %s | %s | %s |  %s" % (
                bonus / RAY * 100, lt_ / RAY, (1 - (1 + bonus / RAY) * lt_ / RAY) * 100, row[0], row[1], row[2],
                "%5.2f" % c5 if c5 is not None else " none"))
    print("  bonus 0%: no clip is ever profitable, the liquidator never acts: identical to L = offline (loss iff the exogenous path alone insolvent).")
    print("  0.00 = the exogenous path alone is past the 49% insolvency point (hour 45) before that liquidator's next look (hour 48).")

    print("\n== 3. Fixed-market accrual cascade (P7): days from a single expiry until the market is unhealthy with NO price move ==")
    print("  Full draw: h = lt/ltv = 1.6, so debt must grow x1.6; cUSD loss when debt > K/(1+b), i.e. a further x%.3f." % (
        (1 / (1 + b / RAY)) / (lt / RAY)))
    print("  DeployInfra sets NO liquidity slopes (rate 0) and no underwriter rate (owner-set): 'deploy rates' = the owner's underwriter rate alone.")
    print("  carry/yr | source                          | rolls to h<1 | days to h<1 | further days to cUSD loss | free credit per day on $10M expired loan")
    T = 30 * DAY
    for carry, src in ((0.05, "uw 5% only (deploy, slopes 0)"), (0.20, "uw 20% only (harness uw, slopes 0)"),
                       (0.30, "harness curve@80% + uw 20%"), (0.40, "same, multiplier 2 (fixed: linear)"),
                       (1.20, "max uw 100% + curve@80% x2")):
        per_roll = 1 + carry * T / SECONDS_PER_YEAR
        import math
        n1 = math.log(1.6) / math.log(per_roll)
        n2 = math.log((1 / (1 + b / RAY)) / (lt / RAY)) / math.log(per_roll)
        print("  %5.0f%%   | %-31s |    %6.1f    |   %6.0f    |          %6.0f           |   $%.0f" % (
            carry * 100, src, n1, n1 * 30, n2 * 30, 10e6 * carry / 365))
    print("  While unhealthy, every borrower's extend() reverts; all of them sit at ZERO rate past expiry until KEEPER extendAdmin (>= grace).")
    print("  $50M of fixed credit at 30%%: $%.0f of free credit per day of keeper delay; grace 1 d guarantees >= $%.0f per expiry." % (
        50e6 * 0.30 / 365, 50e6 * 0.30 / 365))

    print("\n=== HEADLINE ===")
    r1 = simulate(0.5, 1, b, lt)
    r24 = simulate(0.5, 24, b, lt)
    c = crit_k(1, b, lt)
    c24 = crit_k(24, b, lt)
    r6 = simulate(0.5, 6, b, lt)
    c6, c9 = crit_k(6, b, lt), crit_k(1, b, int(0.9e27))
    print("Defaults, impact 0.5%%/$1M: hourly liquidator clears in %d clips with %.1f%% oracle impact and $%.2fM cUSD loss; 6h latency -> $%.2fM; 24h -> $%.2fM." % (
        r1["clips"], r1["impact"] * 100, r1["unrec"] / WAD / 1e6, r6["unrec"] / WAD / 1e6, r24["unrec"] / WAD / 1e6))
    print("Critical impact k* = %s%%/$1M at L=1h, %s at L=6h, %s at L=24h (bonus 2%%, lt 0.8); at lt 0.9 the L=1h threshold is %s%%/$1M." % (
        ("%.2f" % c) if c else "none<=5", ("%.2f" % c6) if c6 else "none<=5", ("%.2f" % c24) if c24 is not None else "none<=5",
        ("%.2f" % c9) if c9 else "none<=5"))
    print("Fixed (P7): at the harness 20% underwriter rate a fully-drawn fixed market goes unhealthy from accrual alone after ~29 rolls (~2.4 y),")
    print("and 12.5 more rolls (~1 y) to cUSD loss; every day of keeper delay past expiry is 100% free credit ($8.2k/day per $10M at 30%).")


if __name__ == "__main__":
    main()
