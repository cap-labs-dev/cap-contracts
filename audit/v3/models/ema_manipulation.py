#!/usr/bin/env python3
"""
ema_manipulation.py - M-2 regression at HEAD a843c1d: cost of parking a par cUSD deposit for one
averaging window to depress averageUtilizationAfterMint before a fixed draw.

Exact replication (capmath.UtilizationAverage): _accrueAverage / _averagingWeight (exponential,
retention = 1 - 1/period) / _carry / averageSupplies, and the HEAD rule in
averageUtilizationAfterMint (IRM L227-239): credit not yet absorbed into the average is added to
BOTH sides, but a reserve-only move (a deposit) is not - a flash deposit in the same block has no
effect (row t=0 below). A deposit that is HELD is folded into the supply average with weight
1 - e^(-t/period): 63% after one period, 86% after two, 95% after three. The deposit is fee-less
(previewDeposit at par, L206-213) and instantly reversible via instantRedeem while the on-hand
reserve covers it (unlockedSupply L184-192: the deposit itself raised the on-hand balance by D).

Attack: t=0 deposit D (Stablecoin._deposit -> IRM.updateLiquidityRate -> observedSupply = S + D);
t=t FixedMarket.borrow(P, 30 d) prices at averageUtilizationAfterMint(P) on the folded averages;
t=t+ instantRedeem(D). Cost = D * r_alt * t / year (+ gas $20); if the parked cUSD is opted in it
ALSO earns D/(phi S + D) of the liquidity premium r*u*S during t, which offsets the cost (phi = 0.5 shown).
Honest reference: the same borrow with no deposit. S = $100M, harness curve, term multiplier 0.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, DAY, HOUR, SECONDS_PER_YEAR, rayDiv, UtilizationAverage, liquidity_rate_default,  # noqa: E402
                     fixed_premium, DEFAULTS)

S = 100_000_000 * WAD
R_ALT = 0.05
GAS = 20.0
TERM = 30 * DAY
PERIODS = [5 * 60, HOUR, DAY]


def quote(C, D, t, period, P):
    """(rate_honest, rate_manip, premium_honest, premium_manip) for a fixed draw P at time t after parking D."""
    ema = UtilizationAverage(0, period)
    ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C, S, C, S
    u_h = ema.average_utilization_after_mint(t, C, P)
    ema = UtilizationAverage(0, period)
    ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C, S, C, S
    ema.accrue(0, C, S + D)                       # deposit at t=0: no fold, observation moves
    u_m = ema.average_utilization_after_mint(t, C, P)
    rh, rm = liquidity_rate_default(u_h), liquidity_rate_default(u_m)
    return rh, rm, fixed_premium(P, TERM, rh, 0)[0], fixed_premium(P, TERM, rm, 0)[0]


def cost(D, t, u, phi=None):
    c = D / WAD * R_ALT * t / SECONDS_PER_YEAR + GAS
    if phi is not None:
        r = liquidity_rate_default(int(u * RAY)) / RAY
        share = D / (phi * S + D)                                  # parked D dilutes the staked base (P8)
        c -= share * r * u * (S / WAD) * t / SECONDS_PER_YEAR      # lender yield earned while parked and opted in
    return c


def main():
    P = 10_000_000 * WAD
    print("ema_manipulation.py  HEAD a843c1d  S=$100M, loan P=$10M for 30 d, r_alt %.0f%%, gas $%.0f\n" % (R_ALT * 100, GAS))
    for u in (0.8, 0.9):
        C = int(S * u)
        rh0, _, ph0, _ = quote(C, 0, 0, HOUR, P)
        print("== live utilization %.0f%%: honest rate after mint %.3f%%, honest 30 d premium $%.0f ==" % (u * 100, rh0 / RAY * 100, ph0 / WAD))
        print("  period | hold t  | D      | weight | manip rate | discount | $ saved | park cost | net (r_alt only) | net if D opted-in (phi 0.5) | ROI")
        for period in PERIODS:
            for frac in (0.0, 1.0, 2.0, 3.0):
                t = int(period * frac)
                for D in (10_000_000 * WAD, 50_000_000 * WAD, 100_000_000 * WAD, 300_000_000 * WAD):
                    if frac == 0.0 and D != 100_000_000 * WAD:
                        continue
                    rh, rm, ph, pm = quote(C, D, t, period, P)
                    saved = (ph - pm) / WAD
                    c1, c2 = cost(D, t, u), cost(D, t, u, 0.5)
                    print("  %6s | %5.1fP  | $%4.0fM | %.3f  |  %6.3f%%   | %5.1f bp | $%6.0f | $%7.0f  |   $%8.0f      |        $%8.0f            | %s" % (
                        ("%dm" % (period // 60)) if period < HOUR else ("%dh" % (period // HOUR)), frac, D / WAD / 1e6,
                        1 - (1 - 1 / period) ** t, rm / RAY * 100, (rh - rm) / RAY * 1e4, saved, c1, saved - c1, saved - c2,
                        ("%.0fx" % (saved / c1)) if c1 > 0 else "-"))
        print()

    print("== break-even and best D per period at u=90% (hold t = period) ==")
    C = int(S * 0.9)
    for period in PERIODS:
        best, first = (0.0, None), None
        for k in range(0, 70):
            D = int(S * 0.001 * 1.12 ** k)
            rh, rm, ph, pm = quote(C, D, period, period, P)
            profit = (ph - pm) / WAD - cost(D, period, 0.9)
            if profit > 0 and first is None:
                first = D
            if profit > best[0]:
                best = (profit, D)
        print("  period %6ds: break-even D = %s, best D = $%.0fM, profit $%.0f" % (
            period, ("$%.1fM" % (first / WAD / 1e6)) if first else "none", best[1] / WAD / 1e6 if best[1] else 0, best[0]))
    print("\n== Why the band [5 min, 1 day] bounds duration, not profitability ==")
    print("  benefit saturates at ~63%/86%/95% of the full depression after 1/2/3 periods; cost is linear in t. A 5-minute period")
    print("  makes the same discount cost 288x less than a 1-day period. The flash (t=0) row shows the HEAD rule working: 0 bp.")
    print("\n=== HEADLINE ===")
    rh, rm, ph, pm = quote(int(S * 0.9), 100_000_000 * WAD, HOUR, HOUR, P)
    rh5, rm5, ph5, pm5 = quote(int(S * 0.9), 100_000_000 * WAD, 5 * 60, 5 * 60, P)
    print("Deploy period 1 h, u=90%%: $100M parked 1 h cuts the $10M 30 d premium $%.0f -> $%.0f (%.0f bp): saves $%.0f for $%.0f of carry (%.0fx);" % (
        ph / WAD, pm / WAD, (rh - rm) / RAY * 1e4, (ph - pm) / WAD, cost(100_000_000 * WAD, HOUR, 0.9), (ph - pm) / WAD / cost(100_000_000 * WAD, HOUR, 0.9)))
    print("at the 5-minute minimum the same discount costs $%.0f. A flash deposit (t=0) now yields 0 bp (HEAD rule), so M-2 is mitigated only" % cost(100_000_000 * WAD, 5 * 60, 0.9))
    print("against same-block deposits; a held deposit still buys the discount at every permitted period. Break-even capital < $10M at u=90%.")


if __name__ == "__main__":
    main()
