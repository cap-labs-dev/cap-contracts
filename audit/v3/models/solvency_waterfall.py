#!/usr/bin/env python3
"""
solvency_waterfall.py - who absorbs a loss: junior -> senior -> cUSD holders (writeOff), at HEAD a843c1d.

Exact pieces (capmath): healthiness, maxLiquidatable, recoverableDebt, unrecoverableDebt, the
_liquidate waterfall with Tranche.slash floor-to-zero / clamp / KILL_RATIO latch, lockedValue (ceil).

Model. One market, two tranches (senior, junior), capital split like the premium weights
(HARNESS 95/5, and 70/30). K0 = $100M of one collateral (price P0). Debt D = x * ltv * K0 with
x = credit-line utilization (x = 1 is a full draw). A jump: price *= (1 - d) (drawdown d) and the
borrower stops paying a fraction f of D ("default fraction"): (1 - f) D is repaid at par, f D is
never repaid and must be cleared by liquidation, which slashes f D (1 + bonus) of collateral value
junior-first. Liquidation needs healthiness < 1 (BaseMarket._liquidate L355) - if the defaulted
residual leaves the market healthy the debt simply sits and accrues (P9, premium_accrual_insolvent.py)
until it is unhealthy; the eventual loss allocation is the same, so this is an "eventual settlement"
model. cUSD holders lose when f D > K/(1+bonus), i.e. d > 1 - f x ltv (1+bonus); lt does not enter
that threshold - it only decides when liquidation becomes POSSIBLE (h < 1 at d = 1 - x ltv / lt).

Correlated case. N markets, each as above, each fully drawn. There is NO restaking code in
contracts/ (plan 00-plan.md s4): correlation enters only through (a) tranches holding the same or
correlated collateral assets and (b) every market's write-off landing on the same cUSD. Per-market
protection is NOT pooled: market j's surplus collateral never covers market i's shortfall, so the
system loss is sum_i max(0, loss_i) >= max(0, sum_i loss_i). One-factor Gaussian log-returns with
correlation rho over a 7-day stress horizon at 80%/yr vol, 20,000 draws (numpy).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, rayMul, healthiness, max_liquidatable, recoverable_debt, unrecoverable_debt,  # noqa: E402
                     liquidate, locked_value, TrancheState, DEFAULTS)

K0 = 100_000_000 * WAD
P0 = 2000 * WAD


def build(shares, price, decimals=18):
    caps = [K0 * s // 100 for s in shares]
    caps[0] += K0 - sum(caps)
    return [TrancheState(c * 10**decimals // price, price, decimals) for c in caps]


def settle(shares, x, d, f, ltv, lt, p=DEFAULTS, decimals=18):
    """Jump d, default fraction f. Returns dict of contract views at the jump and the eventual allocation."""
    b = p["liquidationBonus"]
    price = P0 * (RAY - int(d * RAY)) // RAY
    tr = build(shares, P0, decimals)
    for t in tr:
        t.price = price
    D = int(K0 * (ltv / RAY) * x)
    K = sum(t.total_capital() for t in tr)
    view = dict(K=K, h=healthiness(K, D, lt), maxLiq=max_liquidatable(K, D, lt, p["targetHealth"], b),
                rec=recoverable_debt(K, b), unrec=unrecoverable_debt(K, D, b))
    caps = [t.total_capital() for t in tr]
    view["locked"] = [locked_value(D, lt, p["buffer"], caps, i) for i in range(len(tr))]
    view["unlocked_pct"] = [tr[i].unlocked_supply(view["locked"][i]) * 100 / tr[i].supply for i in range(len(tr))]
    Df = int(D * f)                       # never repaid -> cleared by liquidation
    clearable = min(Df, recoverable_debt(K, b))
    slashed, dust = liquidate(tr, clearable, b) if clearable else ([0] * len(tr), 0)
    view.update(Df=Df, cleared=clearable, slashed=slashed, dust=dust, cusd_loss=Df - clearable,
                killed=[t.killed for t in tr], wiped=[t.assets == 0 for t in tr])
    return view


def threshold_d(shares, x, f, ltv, lt, pred):
    lo, hi = 0.0, 0.9999
    if not pred(settle(shares, x, hi, f, ltv, lt)):
        return None
    for _ in range(30):
        mid = (lo + hi) / 2
        if pred(settle(shares, x, mid, f, ltv, lt)):
            hi = mid
        else:
            lo = mid
    return hi


def section_grid():
    b = DEFAULTS["liquidationBonus"] / RAY
    for shares in ((95, 5), (70, 30)):
        print("== 1. Loss allocation, tranches %d/%d, full draw (x = 1), ltv 0.5, lt 0.8, bonus 2%%, TH 1.25 ==" % shares)
        print("  d      f    | health | maxLiq   | recover. | unrec(view) | junior slashed | senior slashed | cUSD loss | junior wiped/killed")
        for d in (0.0, 0.2, 0.3, 0.375, 0.45, 0.49, 0.55, 0.7):
            for f in (0.25, 0.5, 1.0):
                v = settle(shares, 1.0, d, f, DEFAULTS["ltv"], DEFAULTS["lt"])
                print("  %.3f  %.2f | %6.3f | %8s | %8s | %11s | %14s | %14s | %9s | %s/%s" % (
                    d, f, v["h"] / RAY, "$%.1fM" % (v["maxLiq"] / WAD / 1e6), "$%.1fM" % (v["rec"] / WAD / 1e6),
                    "$%.1fM" % (v["unrec"] / WAD / 1e6), "$%.2fM" % (v["slashed"][1] / WAD / 1e6),
                    "$%.2fM" % (v["slashed"][0] / WAD / 1e6), "$%.2fM" % (v["cusd_loss"] / WAD / 1e6),
                    v["wiped"][1], v["killed"][1]))
        print()

    print("== 2. Smallest drawdown d at which cUSD holders first lose (eventual f D > K/(1+b)), by f, ltv, lt ==")
    print("  analytic: d* = 1 - f x ltv (1+b); h<1 at d_h = 1 - x ltv / lt; 'cushion' = d* - d_h (negative: loss before liquidation is even possible)")
    print("  ltv  lt  |  f=0.25   f=0.50   f=0.75   f=1.00  | d(h<1)  cushion@f=1 | junior wiped at (f=1) | senior touched at (f=1)")
    for ltv, lt in ((0.5, 0.8), (0.7, 0.8), (0.5, 0.9), (0.7, 0.9)):
        ltv_r, lt_r = int(ltv * RAY), int(lt * RAY)
        row = []
        for f in (0.25, 0.5, 0.75, 1.0):
            t = threshold_d((95, 5), 1.0, f, ltv_r, lt_r, lambda v: v["cusd_loss"] > 0)
            row.append("%6.2f%%" % (t * 100) if t is not None else "  never")
        dh = threshold_d((95, 5), 1.0, 1.0, ltv_r, lt_r, lambda v: v["h"] < RAY)
        dj = threshold_d((95, 5), 1.0, 1.0, ltv_r, lt_r, lambda v: v["wiped"][1])
        ds = threshold_d((95, 5), 1.0, 1.0, ltv_r, lt_r, lambda v: v["slashed"][0] > 0)
        d1 = 1 - ltv * (1 + b)
        print("  %.1f  %.1f | %s  | %5.1f%%  %+6.1f%%       | %s | %s" % (
            ltv, lt, "  ".join(row), dh * 100, (d1 - dh) * 100,
            "%5.1f%%" % (dj * 100) if dj is not None else "never", "%5.1f%%" % (ds * 100) if ds is not None else "never"))
    print("  A 5% junior is wiped by ANY full default (f=1) at d=0: slash = 1.02 x $50M = $51M > $5M. It is KILLED (KILL_RATIO 100) in the same call.")
    print("  ltv 0.7 + lt 0.9: cUSD loses at d = 28.6% while h<1 only at 22.2%: 6.4 points of price between 'liquidatable' and 'insolvent'.")
    print("  70/30 at f=0.25 (slash $12.75M): junior wiped at d >= %.1f%%; at f=0.5 ($25.5M): d >= %.1f%%" % (
        (threshold_d((70, 30), 1.0, 0.25, DEFAULTS["ltv"], DEFAULTS["lt"], lambda v: v["wiped"][1]) or 0) * 100,
        (threshold_d((70, 30), 1.0, 0.5, DEFAULTS["ltv"], DEFAULTS["lt"], lambda v: v["wiped"][1]) or 0) * 100))

    print("\n== 3. Floor-to-zero dust rule (Tranche.slash L79-84): value lost per tranche per liquidation ==")
    print("  A request below one token unit converts to 0 assets and is passed on; after the senior it is uncollected.")
    for name, dec, price in (("ETH 18-dec $2000", 18, 2000 * WAD), ("WBTC 8-dec $60k", 8, 60000 * WAD), ("2-dec token $1", 2, WAD)):
        max_lost = price // 10**dec  # value < price/unit floors to zero
        print("  %-18s: max uncollected per tranche = %d wei USD = $%.2e   (price/10^decimals)" % (name, max_lost, max_lost / WAD))
    print("  => slashed < repaid*(1+bonus) by at most (n_tranches x price/unit): negligible unless the token has <= 2 decimals (P10).")


def section_correlated():
    print("\n== 4. Correlated markets: N markets, same draw (x=1, ltv 0.5), shared cUSD; per-market protection NOT pooled ==")
    b = DEFAULTS["liquidationBonus"] / RAY
    rng = np.random.default_rng(7)
    sigma, T = 1.0, 30 / 365
    sd = sigma * np.sqrt(T)
    for ltv in (0.5, 0.7):
        D = ltv
        dstar = 1 - D * (1 + b)
        print("  ltv %.1f: per-market loss needs d > %.1f%%; 30d @ 100%% vol: per-market P(d > d*) = %.4f" % (
            ltv, dstar * 100, float(np.mean(1 - np.exp(sd * rng.standard_normal(200000) - 0.5 * sd**2) > dstar))))
        print("  rho   N | P(system loss>0) | E[loss] % of total debt | E[loss | loss] % | pooled-capital loss % | silo/pooled")
        for rho in (0.0, 0.5, 0.9, 1.0):
            for N in (1, 5, 20, 50):
                M = 20000
                F = rng.standard_normal((M, 1))
                e = rng.standard_normal((M, N))
                r = sd * (rho * F + np.sqrt(1 - rho**2) * e) - 0.5 * sd**2
                K = np.exp(r)                                   # per-market capital, K0 = 1
                loss = np.maximum(0, D - K / (1 + b))           # per market, f = 1
                sys_loss = loss.sum(axis=1) / (N * D)
                pooled = np.maximum(0, N * D - K.sum(axis=1) / (1 + b)) / (N * D)
                pl = float(np.mean(sys_loss > 0))
                el = float(np.mean(sys_loss))
                ell = float(np.mean(sys_loss[sys_loss > 0])) if pl > 0 else 0.0
                ep = float(np.mean(pooled))
                print("  %.1f %3d |      %.4f      |        %6.3f%%          |    %6.2f%%     |       %6.3f%%         |  %s" % (
                    rho, N, pl, el * 100, ell * 100, ep * 100, ("%.1fx" % (el / ep)) if ep > 0 else "inf"))
    print("  Closed form at rho = 0 with per-market loss probability p: P(system loss) = 1 - (1-p)^N.")
    for p in (0.01, 0.02, 0.05):
        n50 = np.log(0.5) / np.log(1 - p)
        print("    p = %.0f%%/period per market: system loss more likely than not from N >= %.0f markets" % (p * 100, np.ceil(n50)))
    print("  Correlation shifts the tail, not the mean: rho 1.0 -> loss in one 'event' but N times larger; rho 0 -> a loss every period at large N.")


if __name__ == "__main__":
    print("solvency_waterfall.py  HEAD a843c1d  K0=$100M, P0=$2000, lt 0.8 / buffer 0.1 / TH 1.25 / bonus 2% (deploy); ltv 0.5, 95/5 (harness)\n")
    section_grid()
    section_correlated()
    b = DEFAULTS["liquidationBonus"] / RAY
    print("\n=== HEADLINE ===")
    print("Full draw at ltv 0.5: junior (5%) is wiped+killed by the first full-default liquidation at ANY drawdown; senior is touched at d=0;")
    print("cUSD holders lose at d >= %.1f%% (f=1) or %.1f%% (f=0.5). At ltv 0.7 the cUSD threshold is %.1f%% and at lt 0.9 the" % (
        (1 - 0.5 * (1 + b)) * 100, (1 - 0.25 * (1 + b)) * 100, (1 - 0.7 * (1 + b)) * 100))
    print("liquidatable point is d=22.2%: only 6.4 points of price separate 'can liquidate' from 'cUSD already lost'. The dust rule costs <= price/10^dec per tranche.")
    print("Silo'd protection: at rho=0 the system loses on 1-(1-p)^N of periods; at p=2% that is >50% from N=35 markets; silo loss exceeds the pooled loss (table 4).")
