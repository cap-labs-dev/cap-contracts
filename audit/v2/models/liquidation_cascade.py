#!/usr/bin/env python3
"""
liquidation_cascade.py - H11: price path -> healthiness < 1 -> maxLiquidatable -> slash at
(1+bonus) -> totalCapital falls -> re-check. Does the system clear or spiral into
unrecoverableDebt, and at what liquidationBonus / lt / targetHealth / volatility?

Exact mechanics (ray ints via capmath): healthiness, maxLiquidatable (incl. the recoverableDebt
cap), _liquidate slash = repaid*(1+bonus) junior-first, Tranche.slash clamp, unrecoverableDebt,
compounded premium accrual on the debt (MathUtils, per step).

Price model: GBM, hourly steps, annualised vol sigma in {40%..200%}, zero drift, 30-day horizon,
N paths per cell. Market impact of the liquidator dumping collateral: the liquidator sells q
units into a book with depth Q (units per 1% impact at the top of book); execution price
P*(1 - LAMBDA*q/Q); a PERM fraction of that impact sticks in the oracle price (the dump moves
the market the oracle reads), the rest reverts next step.

Liquidator behaviour: a single LIQUIDATOR-role actor holding cUSD. Acts when healthiness < 1 AND
the trade is profitable: proceeds of the collateral at the impacted execution price must exceed
the cUSD burned at par. _liquidate accepts any `amount` <= maxLiquidatable, so the liquidator
CHUNKS: each call is sized so its own impact stays at 90% of the bonus (the largest profitable
clip), up to MAX_CHUNKS per hourly step. Permanent impact from each clip lowers the oracle price
for the next one - that feedback is the cascade. If no profitable clip exists it waits (rational);
the debt keeps compounding. Capital requirement = cUSD burned in the step (held at par).

Assumptions: K0 = $100M collateral (ETH-like, P0 $2000), 95/5 tranches, debt drawn to the full
credit line (ltv * K0), carry 30%/yr (liquidity 10% + underwriter 20%). Depth Q = 5,000 ETH per
1% of impact (~$10M) with LAMBDA=1, PERM=0.5 - these are stated, not measured.
"""
import sys
import os
import random
import math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, HOUR, DAY, rayMul, rayDiv, healthiness, max_liquidatable,
                     unrecoverable_debt, recoverable_debt, tranche_slash, compounded_interest, DEFAULTS)  # noqa: E402

try:
    import numpy as np
    HAVE_NP = True
except Exception:
    HAVE_NP = False

random.seed(7)
K0 = 100_000_000 * WAD
P0 = 2000 * WAD
CARRY = int(0.30e27)
STEP = HOUR
HORIZON = 30 * DAY
NPATHS = 80
Q_UNITS = 5000 * WAD   # collateral units sold per 1% impact
LAMBDA = 1.0
PERM = 0.5
MAX_CHUNKS = 40
VOLS = [0.4, 0.6, 0.8, 1.0, 1.25, 1.5, 2.0, 3.0]


def gbm_path(sigma, steps, dt_years, rng):
    p = [1.0]
    for _ in range(steps):
        z = rng.gauss(0, 1)
        p.append(p[-1] * math.exp(-0.5 * sigma**2 * dt_years + sigma * math.sqrt(dt_years) * z))
    return p


def simulate(path, lt, th, bonus, liquidator_online=True, impact=True, q_units=None, check_every=1):
    """Walk one price path. Returns dict with outcome metrics."""
    Q = q_units or Q_UNITS
    caps = [K0 * 95 // 100, K0 * 5 // 100]
    assets = [c * WAD // P0 for c in caps]
    debt = rayMul(K0, DEFAULTS["ltv"])
    perm_mult = 1.0
    cum_slash = 0
    n_liq = 0
    max_liq = 0        # largest cUSD burned in one hourly step
    max_unrec = 0
    profit_total = 0.0
    stalled_steps = 0
    factor = compounded_interest(CARRY, STEP)
    # largest clip (in collateral units) whose impact is 90% of the bonus
    clip_units = int((bonus / RAY) * 0.9 * 100 * Q / LAMBDA) if impact else 10**40
    for i in range(1, len(path)):
        # debt accrues
        debt = rayMul(debt, factor)
        price = int(P0 * path[i] * perm_mult)
        K = sum(a * price // WAD for a in assets)
        burned_this_step = 0
        # try to liquidate in clips within the step while unhealthy and profitable
        for _ in range(MAX_CHUNKS if (i % check_every == 0) else 0):
            h = healthiness(K, debt, lt)
            if h >= RAY or debt == 0:
                break
            liq = max_liquidatable(K, debt, lt, th, bonus)
            if liq == 0:
                break
            # clip: debt amount whose slash value converts to clip_units at the current price
            clip_value = clip_units * price // WAD
            clip_debt = rayDiv(clip_value, RAY + bonus)
            if clip_debt < liq:
                liq = max(clip_debt, 1)
            toSlash = rayMul(liq, RAY + bonus)
            # collateral units the liquidator would receive (junior first)
            units = 0
            rem = toSlash
            tmp_assets = list(assets)
            for j in (1, 0):
                a, v = tranche_slash(rem, tmp_assets[j], price)
                tmp_assets[j] -= a
                units += a
                rem -= v
                if rem == 0:
                    break
            imp = LAMBDA * (units / Q) / 100.0 if impact else 0.0
            exec_price = price * max(0.0, 1 - imp)
            proceeds = units / WAD * exec_price / WAD
            cost = liq / WAD
            if not liquidator_online or proceeds < cost:
                stalled_steps += 1
                break
            # execute
            assets = tmp_assets
            debt -= liq
            cum_slash += toSlash
            n_liq += 1
            burned_this_step += liq
            max_liq = max(max_liq, burned_this_step)
            profit_total += proceeds - cost
            if impact:
                perm_mult *= (1 - PERM * imp)
                price = int(P0 * path[i] * perm_mult)
            K = sum(a * price // WAD for a in assets)
        unrec = unrecoverable_debt(K, debt, bonus)
        max_unrec = max(max_unrec, unrec)
    return dict(unrec=max_unrec, n_liq=n_liq, max_liq=max_liq, cum_slash=cum_slash,
                profit=profit_total, stalled=stalled_steps, final_debt=debt)


def cell(sigma, lt, th, bonus, npaths=NPATHS, **kw):
    rng = random.Random(int(sigma * 1000) + int(lt / 1e24) + int(th / 1e24) + int(bonus / 1e24))
    steps = HORIZON // STEP
    dt = STEP / (365 * DAY)
    losses = 0
    unrec_sum = 0
    max_liq = 0
    n_liq = 0
    stalled = 0
    for _ in range(npaths):
        path = gbm_path(sigma, steps, dt, rng)
        r = simulate(path, lt, th, bonus, **kw)
        if r["unrec"] > 0:
            losses += 1
            unrec_sum += r["unrec"]
        max_liq = max(max_liq, r["max_liq"])
        n_liq += r["n_liq"]
        stalled += r["stalled"]
    return dict(p_loss=losses / npaths, avg_unrec=(unrec_sum / losses / WAD) if losses else 0.0,
                max_liq=max_liq / WAD, n_liq=n_liq / npaths, stalled=stalled / npaths)


def vol_threshold(lt, th, bonus, target=0.5, **kw):
    """Lowest vol in VOLS with p_loss >= target (30d horizon)."""
    for s in VOLS:
        if cell(s, lt, th, bonus, npaths=40, **kw)["p_loss"] >= target:
            return s
    return None


def main():
    p = DEFAULTS
    print("liquidation_cascade.py  K0=$100M ETH-like, debt = ltv*K0 = $50M, carry 30%%, 30d hourly GBM, %d paths/cell" % NPATHS)
    print("impact: LAMBDA %.1f, depth %d units per 1%%, PERM %.1f\n" % (LAMBDA, Q_UNITS // WAD, PERM))

    print("== 1. Defaults (lt 0.8, targetHealth 1.25, bonus 2%): P(cUSD loss within 30d) by vol ==")
    print("vol   | P(loss) | avg unrec when loss | clips/path | max cUSD burned in one hour (liquidator capital) | stalled steps/path")
    for s in VOLS:
        c = cell(s, p["lt"], p["targetHealth"], p["liquidationBonus"])
        print(" %3.0f%% |  %.2f   |    $%8.2fM      |      %5.2f        |            $%6.1fM                    |   %.1f" % (
            s * 100, c["p_loss"], c["avg_unrec"] / 1e6, c["n_liq"], c["max_liq"] / 1e6, c["stalled"]))

    print("\n== 2. Liquidator OFFLINE (H11: single privileged actor): P(loss) by vol ==")
    for s in (0.6, 0.8, 1.0, 1.5):
        c = cell(s, p["lt"], p["targetHealth"], p["liquidationBonus"], liquidator_online=False)
        print(" vol %3.0f%%: P(loss) %.2f  avg unrec $%.2fM" % (s * 100, c["p_loss"], c["avg_unrec"] / 1e6))

    print("\n== 3a. Liquidator LATENCY x lt at 100% vol, bonus 2%, TH 1.25: P(cUSD loss in 30d) ==")
    print("  (the liquidator checks the market every N hours; 'never' = offline). cushion = 1-(1+b)*lt = price drop from h=1 to unrec>0")
    print("  lt   | cushion |  1h   |  6h   |  24h  |  72h  | never")
    for lt in (int(0.7e27), int(0.8e27), int(0.9e27), int(0.95e27)):
        row = []
        for ce in (1, 6, 24, 72, None):
            if ce is None:
                c = cell(1.0, lt, p["targetHealth"], p["liquidationBonus"], npaths=60, liquidator_online=False)
            else:
                c = cell(1.0, lt, p["targetHealth"], p["liquidationBonus"], npaths=60, check_every=ce)
            row.append("%.2f" % c["p_loss"])
        print("  %.2f |  %4.1f%%  | %s" % (lt / RAY, (1 - (1 + p["liquidationBonus"] / RAY) * lt / RAY) * 100, " | ".join("%5s" % x for x in row)))

    print("\n== 3b. Same at 150% vol ==")
    print("  lt   | cushion |  1h   |  6h   |  24h  |  72h  | never")
    for lt in (int(0.7e27), int(0.8e27), int(0.9e27), int(0.95e27)):
        row = []
        for ce in (1, 6, 24, 72, None):
            if ce is None:
                c = cell(1.5, lt, p["targetHealth"], p["liquidationBonus"], npaths=60, liquidator_online=False)
            else:
                c = cell(1.5, lt, p["targetHealth"], p["liquidationBonus"], npaths=60, check_every=ce)
            row.append("%.2f" % c["p_loss"])
        print("  %.2f |  %4.1f%%  | %s" % (lt / RAY, (1 - (1 + p["liquidationBonus"] / RAY) * lt / RAY) * 100, " | ".join("%5s" % x for x in row)))

    print("\n== 3c. bonus x lt x targetHealth: first-liquidation size at h=1 and vol at which an ONLINE liquidator still loses ==")
    print("bonus | lt   | targetHealth | perCleared = TH-(1+b)*lt | first-liq size at h=1 (% of debt) | vol threshold P(loss)>=50%")
    for bonus in (0, int(0.02e27), int(0.10e27)):
        for lt in (int(0.7e27), int(0.8e27), int(0.9e27)):
            for th in (int(1.25e27), int(1.5e27), int(2e27)):
                perCleared = th - rayMul(RAY + bonus, lt)
                first = ((th - RAY) / RAY) / (perCleared / RAY) * 100 if perCleared > 0 else float("inf")
                vt = vol_threshold(lt, th, bonus)
                print(" %3.0f%%  | %.2f |     %.2f     |        %.3f             |   %3.0f%%                          |    %s" % (
                    bonus / RAY * 100, lt / RAY, th / RAY, perCleared / RAY, min(first, 100), ("%.0f%%" % (vt * 100)) if vt else ">300%"))
    print("  bonus 0% rows equal the OFFLINE case: no clip is ever profitable, so the liquidator never acts.")

    print("\n== 4. Liquidator economics per unit of debt cleared (no path; static) ==")
    print("collateral/debt | recoverable share | bonus 0% | bonus 2% | bonus 5% | bonus 10%   (profit per $1 cUSD burned, before impact)")
    for cr in (1.5, 1.25, 1.1, 1.05, 1.02, 1.0, 0.9, 0.5):
        # liquidator gets (1+b) per debt unit while collateral covers; maxLiquidatable caps at recoverable
        rec = [min(1.0, cr / (1 + b)) for b in (0, 0.02, 0.05, 0.10)]
        print("     %.2f       |   %s   | %s" % (cr, "/".join("%.2f" % x for x in rec),
                                              " | ".join("%+5.1f%%" % b for b in (0, 2, 5, 10))))
    print("  The liquidator ALWAYS earns exactly the bonus per unit cleared (maxLiquidatable is capped at")
    print("  recoverableDebt, so the tranche is never asked for more than it holds). Below 100% collateral the")
    print("  liquidator still profits on the recoverable slice; the UNRECOVERABLE slice is simply not liquidatable")
    print("  and lands on cUSD holders via writeOff. Net of impact the trade is profitable iff bonus > impact:")
    for bonus in (0.0, 0.02, 0.05, 0.10):
        q = bonus * 100 * Q_UNITS / WAD / LAMBDA
        if bonus > 0:
            print("   bonus %3.0f%%: largest single clip that still clears = %6.0f units (~$%.1fM at $2000, depth %d/1%%)" % (
                bonus * 100, q, q * 2000 / 1e6, Q_UNITS // WAD))
        else:
            print("   bonus   0%: liquidation is NEVER profitable (proceeds <= cUSD burned); permitted by setLiquidationBonus(0)")

    print("\n== 4b. Depth sensitivity at 100% vol, defaults: P(loss) and clips by book depth ==")
    for qd in (1000, 2000, 5000, 20000):
        c = cell(1.0, p["lt"], p["targetHealth"], p["liquidationBonus"], npaths=60, q_units=qd * WAD)
        print("  depth %5d units/1%% (~$%3.0fM): P(loss) %.2f  clips/path %5.1f  max cUSD/hour $%.1fM  stalled %.1f" % (
            qd, qd * 2000 / 1e6, c["p_loss"], c["n_liq"], c["max_liq"] / 1e6, c["stalled"]))

    print("\n== 5. Capital requirement: cUSD the liquidator must hold at the first liquidation ==")
    for x, shocks in ((0.5, (0.69, 0.72, 0.745)), (1.0, (0.38, 0.45, 0.49))):
        debt = int(K0 * 0.5 * x)
        for shock in shocks:
            K = int(K0 * (1 - shock))
            liq = max_liquidatable(K, debt, p["lt"], p["targetHealth"], p["liquidationBonus"])
            print("  credit-util %3.0f%% shock %4.1f%%: debt $%.0fM, maxLiquidatable $%.1fM (%.0f%% of debt) -> liquidator needs $%.1fM cUSD at par" % (
                x * 100, shock * 100, debt / WAD / 1e6, liq / WAD / 1e6, liq / debt * 100 if debt else 0, liq / WAD / 1e6))

    print("\n=== HEADLINE ===")
    c80 = cell(0.8, p["lt"], p["targetHealth"], p["liquidationBonus"])
    c80off = cell(0.8, p["lt"], p["targetHealth"], p["liquidationBonus"], liquidator_online=False)
    vt = vol_threshold(p["lt"], p["targetHealth"], p["liquidationBonus"])
    print("Defaults, ETH at 80%% vol, 30d: P(cUSD loss) = %.2f with a clip-sizing liquidator online vs %.2f offline;"
          " P(loss) >= 50%% only above ~%s annualised vol." % (c80["p_loss"], c80off["p_loss"], ("%.0f%%" % (vt * 100)) if vt else "300%"))
    print("The first liquidation at health=1 wants 58% of debt at TH 1.25 (73% at TH 1.5, 84% at TH 2.0); at 2% bonus the")
    print("largest clip with positive edge is ~$20M at the stated depth, so restoring health takes several clips whose")
    print("permanent impact lowers the oracle price for the next. Bonus 0% (permitted) makes every liquidation unprofitable.")


if __name__ == "__main__":
    main()
