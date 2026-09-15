#!/usr/bin/env python3
"""
ema_manipulation.py - H10: cost to depress the time-weighted utilization vs the fixed-rate
premium it saves on a max-term loan, across the whole permitted averagingPeriod band.

Exact replication (ray ints, contracts/cap/InterestRateModel.sol):
  _accrueAverage / _averagingWeight / _carry / averageSupplies / averageUtilizationAfterMint
  _nextLiquidityRate (curve), termMultiplier, fixedRatesAfterMint
  FixedMarket._premium (linear, per-second prorated), _principalWithin

Attack (all permissionless except the borrow, which the attacker must hold the BORROWER role
for on some fixed market - i.e. this is a *borrower* extracting a discount, not an outsider):
  t=0  attacker deposits D underlying into Stablecoin at par (no fee). Stablecoin._deposit ->
       IRM.updateLiquidityRate -> _accrueAverage: the interval before t=0 is folded with the OLD
       observation, and the new supply (S+D) becomes the standing observation.
  t=t  attacker calls FixedMarket.borrow(L, maxTerm). _borrow mints L (mintCreditBacked ->
       _accrueAverage folds [0,t] with the (S+D, C) observation at weight min(t/period, 1)), then
       _chargePremiumForTerm prices at averageUtilizationAfterMint(L) on those averages.
  t=t+ attacker redeems D at par (instant, if instantUnlockedSupply >= D - it is, the deposit
       itself raised unlockedSupply by D, unless a redemption queue is already standing).
Cost    = D * r_alt * t / year (opportunity cost of capital) + gas (2 txs ~ $20).
Benefit = L * term * (rate_honest - rate_manipulated) * termMultiplier / year.
The borrow ITSELF moves utilization: honest rate is at averageUtilizationAfterMint(L) with
no deposit; manipulated at the same with (S+D) in the average.

Assumptions:
  * S = $100M cUSD, C = 80% utilized (rate at the kink); also 90% (on the steep slope).
    Curve base 5% / slope0 5% / slope1 10% / kink 80% (CapDeployer). termMultiplierSlope 0 (deploy
    default) and 0.5e27 (shown, makes short terms dearer; max term always pays the plain rate).
  * The EMA has been quiet: averages == live values at t=0 (worst case for the attacker; any
    prior deposits would already have pushed the average down).
  * r_alt = 5%/yr opportunity cost on the manipulation capital. Term = maximumTermLimit = 30 d.
  * Nobody else touches the stablecoin during [0, t]. Any other supply movement re-folds with the
    attacker's observation still standing, which only helps the attacker.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, DAY, HOUR, SECONDS_PER_YEAR, rayMul, rayDiv, UtilizationAverage,
                     liquidity_rate_default, term_multiplier, fixed_premium, DEFAULTS)  # noqa: E402

S = 100_000_000 * WAD
R_ALT = 0.05
GAS = 20.0  # USD for two transactions
TERM = DEFAULTS["maximumTermLimit"]
PERIODS = [5 * 60, 15 * 60, HOUR, 4 * HOUR, 12 * HOUR, DAY]
LOANS = [1_000_000 * WAD, 10_000_000 * WAD, 50_000_000 * WAD]


def fixed_rate(avg_util, term, tm_slope):
    projected = liquidity_rate_default(avg_util)
    tu = rayDiv(term, DEFAULTS["maximumTermLimit"])
    return rayMul(projected, term_multiplier(tu, tm_slope))  # marketMultiplier 1


def premium_for(L, term, avg_util, tm_slope):
    liq, _ = fixed_premium(L, term, fixed_rate(avg_util, term, tm_slope), 0)
    return liq


def run(C, D, t, period, L, tm_slope=0):
    """Returns (honest_premium, manipulated_premium, avg_util_honest, avg_util_manip)."""
    # honest: no deposit, average == live
    ema = UtilizationAverage(0, period)
    ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C, S, C, S
    u_h = ema.average_utilization_after_mint(t, L)
    # manipulated: deposit at t=0, borrow at t
    ema = UtilizationAverage(0, period)
    ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C, S, C, S
    ema.accrue(0, C, S + D)          # deposit: elapsed 0 -> no fold, observation updated
    ema.accrue(t, C + L, S + D + L)  # borrow mint: folds [0,t] with (C, S+D)
    u_m = ema.average_utilization_after_mint(t, L)  # elapsed 0 after fold -> the folded averages
    return premium_for(L, TERM, u_h, tm_slope), premium_for(L, TERM, u_m, tm_slope), u_h, u_m


def cost(D, t):
    return D / WAD * R_ALT * t / SECONDS_PER_YEAR + GAS


def breakeven_D(C, t, period, L, tm_slope=0):
    """Smallest D (grid) with profit > 0, and the D maximising profit."""
    best = (0.0, None)
    first = None
    for k in range(0, 61):
        D = int(S * (1.13 ** k) * 0.001)  # 0.1% .. ~1500x supply
        ph, pm, _, _ = run(C, D, t, period, L, tm_slope)
        profit = (ph - pm) / WAD - cost(D, t)
        if profit > 0 and first is None:
            first = D
        if profit > best[0]:
            best = (profit, D)
    return first, best


def main():
    print("ema_manipulation.py  S=$100M, r_alt %.0f%%, term = max = %dd, gas $%.0f" % (R_ALT * 100, TERM // DAY, GAS))
    for tm_slope in (0,):
        for u0 in (0.80, 0.90):
            C = int(S * u0)
            print("\n== live utilization %.0f%% (rate %.2f%%) ==" % (u0 * 100, liquidity_rate_default(int(u0 * RAY)) / RAY * 100))
            for L in LOANS:
                ph0 = premium_for(L, TERM, UtilizationAverage(0, HOUR).__class__ and rayDiv(C + L, S + L), tm_slope)
                print("  loan %s: honest 30d premium %s (rate at u_after_mint %.2f%%)" % (
                    "$%.0fM" % (L / WAD / 1e6), "$%.0f" % (ph0 / WAD),
                    liquidity_rate_default(rayDiv(C + L, S + L)) / RAY * 100))
                print("  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD")
                for period in PERIODS:
                    first, (bp, bD) = breakeven_D(C, period, period, L, tm_slope)
                    ph, pm, uh, um = run(C, bD, period, period, L, tm_slope) if bD else (0, 0, 0, 0)
                    # half period: weight 0.5
                    if bD:
                        ph2, pm2, _, _ = run(C, bD, period // 2, period, L, tm_slope)
                        p2 = (ph2 - pm2) / WAD - cost(bD, period // 2)
                    else:
                        p2 = 0
                    print("  %7s  | %-22s | %-11s | %-9s | %-9s | %6.2f%% | %s" % (
                        ("%dm" % (period // 60)) if period < HOUR else ("%dh" % (period // HOUR)),
                        ("$%.1fM" % (first / WAD / 1e6)) if first else "none",
                        ("$%.0fM" % (bD / WAD / 1e6)) if bD else "-",
                        "$%.0f" % bp, "$%.0f" % ((ph - pm) / WAD) if bD else "-", um / RAY * 100 if bD else 0,
                        "$%.0f" % p2))
    print("\n== termMultiplier: shorter terms pay MORE (slope 0.5e27), so the max term is both the cheapest and the")
    print("   one that locks the manipulated rate longest; the multiplier does not touch the attack at max term ==")
    C = int(S * 0.9)
    L = 10_000_000 * WAD
    for term_d in (1, 7, 15, 30):
        term = term_d * DAY
        tu = rayDiv(term, DEFAULTS["maximumTermLimit"])
        for tm_slope in (0, int(0.5e27)):
            mult = term_multiplier(tu, tm_slope)
            ema = UtilizationAverage(0, DAY)
            ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C, S, C, S
            uh = ema.average_utilization_after_mint(DAY, L)
            ema.accrue(0, C, S + S); ema.accrue(DAY, C + L, S + S + L)
            um = ema.average_utilization_after_mint(DAY, L)
            ph = fixed_premium(L, term, fixed_rate(uh, term, tm_slope), 0)[0]
            pm = fixed_premium(L, term, fixed_rate(um, term, tm_slope), 0)[0]
            print("  term %2dd slope %.1f: multiplier %.3f honest $%-7.0f manipulated(D=1x S, t=1d) $%-7.0f saved $%.0f" % (
                term_d, tm_slope / RAY, mult / RAY, ph / WAD, pm / WAD, (ph - pm) / WAD))
    # sensitivity to r_alt and the effect of holding longer than the period (no extra benefit)
    print("\n== Why the band does not help: benefit saturates at t = period, cost is linear in t ==")
    C = int(S * 0.9)
    L = 10_000_000 * WAD
    D = S  # 1x supply
    for period in (5 * 60, HOUR, DAY):
        row = []
        for frac in (0.25, 0.5, 1.0, 2.0):
            t = int(period * frac)
            ph, pm, _, _ = run(C, D, t, period, L)
            row.append("t=%.2fP: saved $%.0f cost $%.0f" % (frac, (ph - pm) / WAD, cost(D, t)))
        print("  period %6ds: " % period + " | ".join(row))
    print("\n== Attacker needs BORROWER role; but the same lever prices EVERY fixed borrow in the window: ==")
    print("   a $100M deposit held 1 day depresses the average for all borrowers for the next period.")
    print("\n=== HEADLINE ===")
    ph, pm, uh, um = run(int(S * 0.9), S, DAY, DAY, 10_000_000 * WAD)
    print("At the MAXIMUM averaging period (1 day), u=90%%, a $100M par deposit held 24h cuts a $10M 30-day fixed"
          " premium from $%.0f to $%.0f (saves $%.0f) at a cost of $%.0f: %.0fx return. At the minimum (5 min) the"
          " cost is $%.0f." % (ph / WAD, pm / WAD, (ph - pm) / WAD, cost(S, DAY), (ph - pm) / WAD / cost(S, DAY), cost(S, 5 * 60)))
    print("The band [5 min, 1 day] bounds the attack's DURATION, not its profitability; break-even D is < 1x supply at every period.")


if __name__ == "__main__":
    main()
