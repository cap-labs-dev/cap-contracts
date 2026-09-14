#!/usr/bin/env python3
"""
coverage_dynamics.py - is reported coverage leading or lagging? HEAD a843c1d.

Three "coverage" readings exist and they update at different times:
  1. BaseMarket.healthiness (L230-234): LIVE - every tranche's totalCapital is priced at the oracle
     on every call. Leads insolvency by the price cushion between h < 1 (d = 1 - x ltv/lt) and
     unrecoverableDebt > 0 (d = 1 - x ltv (1+bonus)).
  2. Underwriter.totalAssets (L243-245) = idle vault balance + totalDebt, where debt[tranche] is
     Tranche.convertToAssets(shares) IN COLLATERAL TOKENS as of the last _mark (allocate /
     deallocate / KEEPER report, L187-203). Two consequences: (a) a price fall never appears in the
     book at all (it is denominated in tokens); (b) a slash removes tokens from the tranche
     immediately but reaches the book only at the next report. The NatSpec calls this lag intentional.
  3. Stablecoin.backing (L195-197) = totalSupply - badDebt: par until GUARDIAN writeOff, whatever
     unrecoverableDebt says.
Also tracked: Tranche.unlockedSupply (L163-174): lockedValue = ceil(debt/(lt-buffer)) minus juniors,
converted to tokens at the live price (ceil) and to shares (ceil).

Stress path: price falls x% per hour for 24 h, then flat to 48 h. One market, K0 = $100M ETH-like,
95/5 tranches, full draw D = $50M (ltv 0.5), floating debt accruing at 30%/yr (harness curve at
u = 80%: 10% liquidity + 20% underwriter; DeployInfra sets no slopes, so this is an assumption),
stepped hourly with MathUtils.calculateCompoundedInterest. A single LIQUIDATOR acts every L hours
(L = 0: every hour) and clears maxLiquidatable in one call; no market impact (see
liquidation_cascade.py for that). One Underwriter holds every senior share, no idle balance; KEEPER
reports every R hours. cUSD supply S = $100M.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, HOUR, rayMul, healthiness, max_liquidatable, recoverable_debt, unrecoverable_debt,  # noqa: E402
                     liquidate, locked_value, compounded_interest, TrancheState, DEFAULTS)

K0 = 100_000_000 * WAD
P0 = 2000 * WAD
S_CUSD = 100_000_000 * WAD
CARRY = int(0.30e27)


def run(x, L, R, hours=48, p=DEFAULTS, verbose=False):
    lt, buf, th, b = p["lt"], p["buffer"], p["targetHealth"], p["liquidationBonus"]
    tr = [TrancheState(K0 * 95 // 100 * WAD // P0, P0), TrancheState(K0 * 5 // 100 * WAD // P0, P0)]
    uw_shares = tr[0].supply
    book = tr[0].convert_to_assets(uw_shares)       # underwriter's debt[senior] at t=0 (tokens)
    debt = rayMul(K0, p["ltv"])
    factor = compounded_interest(CARRY, HOUR)
    rows, slash_time, report_time = [], None, None
    first = dict(h=None, unrec=None, sen0=None, jun0=None, liq=None, book=None)
    for t in range(0, hours + 1):
        if t > 0:
            debt = rayMul(debt, factor)
            price = int(P0 * (1 - x) ** min(t, 24))
            for tt in tr:
                tt.price = price
        K = sum(tt.total_capital() for tt in tr)
        h = healthiness(K, debt, lt)
        liq = 0
        acted = (L == 0 and t > 0) or (L > 0 and t > 0 and t % L == 0)
        if acted and h < RAY:
            liq = max_liquidatable(K, debt, lt, th, b)
            liquidate(tr, liq, b)
            debt -= liq
            K = sum(tt.total_capital() for tt in tr)
            h = healthiness(K, debt, lt)
            if slash_time is None:
                slash_time = t
        live = tr[0].convert_to_assets(uw_shares)
        if t > 0 and t % R == 0:
            book = live
            if slash_time is not None and report_time is None and book == live:
                report_time = t
        unrec = unrecoverable_debt(K, debt, b)
        prot = min(1.0, recoverable_debt(K, b) / debt) if debt else 1.0
        caps = [tt.total_capital() for tt in tr]
        unl = [tr[i].unlocked_supply(locked_value(debt, lt, buf, caps, i)) * 100 / tr[i].supply for i in range(2)]
        true_backing = 1 - unrec / S_CUSD
        rows.append((t, tr[0].price, K, debt, h, liq, unrec, prot, unl, book, live, true_backing))
        if first["h"] is None and h < RAY:
            first["h"] = t
        if first["unrec"] is None and unrec > 0:
            first["unrec"] = t
        if first["sen0"] is None and unl[0] == 0:
            first["sen0"] = t
        if first["liq"] is None and liq > 0:
            first["liq"] = t
    if verbose:
        print("  hr | price  | K      | debt   | health | liq this hr | unrec  | protect | sen.unl | jun.unl | UW book tok | live tok | book stale% | cUSD backing (reported/true)")
        for r in rows:
            if r[0] % 2 or r[0] > 30:
                if r[0] not in (33, 36, 48):
                    continue
            t, price, K, debt, h, liq, unrec, prot, unl, book, live, tb = r
            stale = (book - live) * 100 / book if book else 0
            print("  %2d | $%5.0f | $%5.1fM | $%5.1fM | %6.3f | %8s    | $%5.1fM | %6.3f  | %5.1f%%  | %5.1f%%  | %8.1f    | %8.1f | %6.2f%%     | 100%% / %.2f%%" % (
                t, price / WAD, K / WAD / 1e6, debt / WAD / 1e6, h / RAY, ("$%.1fM" % (liq / WAD / 1e6)) if liq else "-",
                unrec / WAD / 1e6, prot, unl[0], unl[1], book / WAD, live / WAD, stale, tb * 100))
    return rows, first, slash_time, report_time


def main():
    print("coverage_dynamics.py  HEAD a843c1d  K0=$100M, D=$50M, 95/5, carry 30%/yr, cUSD S=$100M\n")
    print("== 1. Path x = 3%/h for 24 h (d = 51.9%), liquidator every hour (L=1), keeper report every 6 h (R=6) ==")
    run(0.03, 1, 6, verbose=True)
    print("\n== 2. Same path, liquidator latency L = 24 h (first look at hour 24), report every 24 h ==")
    run(0.03, 24, 24, verbose=True)

    print("\n== 3. First-event hours by path steepness x and liquidator latency L (no report needed for these) ==")
    print("  x/h  | d@24h | h<1 at | senior unlocked=0 at | unrec>0 (L=off) | first liq (L=1) | first liq (L=6) | unrec>0 (L=6) | unrec>0 (L=24) | max unrec L=24")
    for x in (0.01, 0.02, 0.03, 0.04):
        _, f_off, _, _ = run(x, 10**6, 10**6)
        _, f1, _, _ = run(x, 1, 1)
        _, f6, _, _ = run(x, 6, 6)
        rows24, f24, _, _ = run(x, 24, 24)
        mx = max(r[6] for r in rows24)
        fmt = lambda v: ("%3dh" % v) if v is not None else "  -"
        print("  %.0f%%  | %4.1f%% |  %s   |        %s          |      %s        |      %s       |      %s       |     %s      |     %s       | $%.1fM" % (
            x * 100, (1 - (1 - x) ** 24) * 100, fmt(f_off["h"]), fmt(f_off["sen0"]), fmt(f_off["unrec"]), fmt(f1["liq"]),
            fmt(f6["liq"]), fmt(f6["unrec"]), fmt(f24["unrec"]), mx / WAD / 1e6))

    print("\n== 4. Underwriter book lag vs KEEPER report cadence R (x = 3%/h, liquidator L = 1) ==")
    print("  R    | slash at | book updated at | lag (h) | senior tokens slashed | book overstated by | % of slash unrecognised until report")
    for R in (1, 6, 24):
        rows, f, st, rt = run(0.03, 1, R)
        t0 = rows[st]
        book_before = rows[st - 1][9]
        live_after = rows[st][10]
        lag = (rt - st) if rt else None
        over = book_before - live_after
        print("  %2dh  |   %2dh    |      %s        |   %s   |     %8.1f tok       |   %8.1f tok      | 100%% for %s h, then 0" % (
            R, st, ("%2dh" % rt) if rt else " -", ("%2d" % lag) if lag is not None else " -", (book_before - live_after) / WAD, over / WAD,
            lag if lag is not None else "-"))
    print("  Between the slash and the report an Underwriter depositor is quoted the pre-slash token count (P4, WS-C); a price move never")
    print("  changes the book because it is denominated in collateral tokens - the Underwriter's USD coverage is NEVER reported on-chain.")

    print("\n== 5. Critical hourly fall x (bisection, 48 h horizon) at which cUSD holders lose, by liquidator latency L ==")
    crit = {}
    for L in (1, 6, 12, 24, 10**6):
        lo, hi = 0.0, 0.2
        for _ in range(20):
            mid = (lo + hi) / 2
            rows, _, _, _ = run(mid, L, L)
            if max(r[6] for r in rows) > 0:
                hi = mid
            else:
                lo = mid
        crit[L] = hi
        print("  L = %-7s: x* = %.2f%%/h  (24 h drawdown %.1f%%)" % (("%dh" % L) if L < 10**6 else "offline", hi * 100, (1 - (1 - hi) ** 24) * 100))
    print("  (x* for an hourly liquidator is the single-hour jump that skips the 11.5-point cushion; offline = the 49% insolvency point)")

    print("\n=== HEADLINE ===")
    _, f_off, _, _ = run(0.03, 10**6, 10**6)
    rows24, f24, _, _ = run(0.03, 24, 24)
    print("healthiness() LEADS: at 3%%/h it crosses 1 at hour %d, senior unlockedSupply hits 0 at hour %d, cUSD loss (unrec>0) at hour %d with no" % (
        f_off["h"], f_off["sen0"], f_off["unrec"]))
    print("liquidator - a %d-hour window; a 24-hourly liquidator loses $%.1fM of it. cUSD loss needs x >= %.2f%%/h (L=1h), %.2f%%/h (L=6h), %.2f%%/h (L=24h)." % (
        f_off["unrec"] - f_off["h"], max(r[6] for r in rows24) / WAD / 1e6, crit[1] * 100, crit[6] * 100, crit[24] * 100))
    print("The Underwriter book LAGS every slash by up to the report cadence (0/2/8 h at R = 1/6/24 h here) and never reflects price (token-")
    print("denominated). cUSD backing() reports 100% until GUARDIAN writeOff, whatever unrecoverableDebt says.")


if __name__ == "__main__":
    main()
