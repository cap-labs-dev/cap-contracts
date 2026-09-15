#!/usr/bin/env python3
"""
solvency_waterfall.py - correlated collateral drawdown through the junior -> senior slash
waterfall. Reports, as numbers, the shock at which (a) the junior tranche is wiped, (b) the
senior tranche is touched, (c) unrecoverableDebt > 0 (cUSD holders first take a loss), for each
initial utilization of the credit line; and whether healthiness() leads or lags real protection.

Mechanics replicated exactly (ray ints):
  BaseMarket.healthiness           = totalCapital * lt / debt
  BaseMarket.recoverableDebt       = totalCapital / (1 + bonus)
  BaseMarket.unrecoverableDebt     = debt - recoverable  (if positive)
  BaseMarket.maxLiquidatable       = (targetHealth*debt - totalCapital*lt) / (targetHealth - (1+bonus)*lt), capped
  BaseMarket._liquidate            slash = repaid * (1+bonus), taken from the LAST tranche first
  Tranche.slash                    assets = value*1e18/price, clamped to totalAssets; kill latch at
                                   totalSupply > totalAssets*100
  BaseMarket.variableCreditLimit   = sum(activeCapital) * ltv

Assumptions:
  * All tranches hold the SAME asset class (correlated, one price). A shock s multiplies every
    tranche's price by (1 - s) at once (a jump, no liquidation in between). Total capital K0 = $100M.
  * Tranche CAPITAL is split in the same proportion as the premium WEIGHTS (95/5 default; also
    3-5 tranches). This is an assumption: weights only govern premium, capital is whatever
    underwriters chose to post. Junior capital share is also swept independently.
  * Credit-line utilization x = debt / variableCreditLimit = debt / (ltv * K0), swept 25..100%,
    plus the extreme "debt at lt" (x = lt/ltv = 160%, reachable only via premium accrual or a
    prior price fall, never via borrow).
  * Single liquidator, acts immediately after the shock if profitable (bonus > 0), liquidating
    maxLiquidatable once; then we report the post-liquidation state.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, rayMul, rayDiv, healthiness, recoverable_debt, unrecoverable_debt,
                     max_liquidatable, tranche_slash, DEFAULTS, fmt_ray)  # noqa: E402

K0 = 100_000_000 * WAD
P0 = 2000 * WAD  # collateral price, ETH-like, 18dp


class Tranche:
    def __init__(self, capital_usd, price):
        self.assets = capital_usd * WAD // price  # collateral units
        self.supply = self.assets  # 1:1 shares at par
        self.killed = False

    def capital(self, price):
        return self.assets * price // WAD

    def slash(self, value, price):
        assets, slashedValue = tranche_slash(value, self.assets, price)
        self.assets -= assets
        if not self.killed and self.supply > self.assets * DEFAULTS["KILL_RATIO"]:
            self.killed = True
        return slashedValue


def build(weights, junior_share=None):
    """weights: list of ray weights senior->junior. Capital split by weights unless junior_share set."""
    n = len(weights)
    if junior_share is not None and n == 2:
        caps = [K0 - int(K0 * junior_share), int(K0 * junior_share)]
    else:
        caps = [K0 * w // RAY for w in weights]
        caps[0] += K0 - sum(caps)
    return [Tranche(c, P0) for c in caps]


def walk(tranches, debt, shock, p=DEFAULTS, liquidate=True):
    price = P0 * (RAY - int(shock * RAY)) // RAY
    K = sum(t.capital(price) for t in tranches)
    h = healthiness(K, debt, p["lt"])
    unrec = unrecoverable_debt(K, debt, p["liquidationBonus"])
    res = dict(K=K, h=h, unrec_pre=unrec, liq=0, slashed=[0] * len(tranches), h_post=h, unrec_post=unrec,
               junior_wiped=False, senior_touched=False, killed=[])
    if liquidate and h < RAY:
        liq = max_liquidatable(K, debt, p["lt"], p["targetHealth"], p["liquidationBonus"])
        res["liq"] = liq
        toSlash = rayMul(liq, RAY + p["liquidationBonus"])
        for i in range(len(tranches) - 1, -1, -1):
            got = tranches[i].slash(toSlash, price)
            res["slashed"][i] = got
            toSlash -= got
            if toSlash == 0:
                break
        debt -= liq
        K = sum(t.capital(price) for t in tranches)
        res["h_post"] = healthiness(K, debt, p["lt"])
        res["unrec_post"] = unrecoverable_debt(K, debt, p["liquidationBonus"])
        res["junior_wiped"] = tranches[-1].assets == 0
        res["senior_touched"] = res["slashed"][0] > 0
        res["killed"] = [i for i, t in enumerate(tranches) if t.killed]
    return res


def find_threshold(weights, debt, pred, junior_share=None, liquidate=True):
    """Smallest shock (bisection, 1e-5 precision) for which pred(result) is true."""
    lo, hi = 0.0, 0.999
    tr = build(weights, junior_share)
    if not pred(walk(tr, debt, hi, liquidate=liquidate)):
        return None
    for _ in range(24):
        mid = (lo + hi) / 2
        tr = build(weights, junior_share)
        if pred(walk(tr, debt, mid, liquidate=liquidate)):
            hi = mid
        else:
            lo = mid
    return hi


def section_thresholds(p=DEFAULTS):
    ltv, lt, b = p["ltv"], p["lt"], p["liquidationBonus"]
    print("== 1. Shock thresholds, 2 tranches, capital split 95/5, lt %.2f ltv %.2f bonus %.0f%% targetHealth %.2f ==" % (
        lt / RAY, ltv / RAY, b / RAY * 100, p["targetHealth"] / RAY))
    print("credit-util | debt/K0 | health<1 at | junior wiped | senior touched | cUSD LOSS (unrec>0, jump, no liq) | unrec>0 AFTER one liquidation")
    weights = p["weights"]
    for x in (0.25, 0.5, 0.75, 1.0, lt / ltv):
        debt = int(K0 * (ltv / RAY) * x)
        s_h = find_threshold(weights, debt, lambda r: r["h"] < RAY, liquidate=False)
        s_j = find_threshold(weights, debt, lambda r: r["junior_wiped"])
        s_s = find_threshold(weights, debt, lambda r: r["senior_touched"])
        s_u = find_threshold(weights, debt, lambda r: r["unrec_pre"] > 0, liquidate=False)
        s_u2 = find_threshold(weights, debt, lambda r: r["unrec_post"] > 0)
        s_k = find_threshold(weights, debt, lambda r: len(r["killed"]) > 0)
        f = lambda v: ("%.2f%%" % (v * 100)) if v is not None else "never"
        print("  %5.0f%%    |  %.3f  |   %7s   |   %7s    |    %7s     |            %7s              |      %7s      | junior KILLED at %s" % (
            x * 100, debt / K0, f(s_h), f(s_j), f(s_s), f(s_u), f(s_u2), f(s_k)))
    print("  analytic: health<1 at s = 1 - debt/(K0*lt); unrec>0 at s = 1 - debt*(1+bonus)/K0")


def section_junior_share(p=DEFAULTS):
    print("\n== 2. Junior capital share needed so the junior absorbs a full liquidation (credit-util 100%) ==")
    ltv = p["ltv"]
    debt = int(K0 * (ltv / RAY))
    print("junior share | shock at junior wiped | shock at senior touched | shock unrec>0")
    for js in (0.05, 0.10, 0.20, 0.30, 0.40, 0.5):
        s_j = find_threshold(p["weights"], debt, lambda r: r["junior_wiped"], junior_share=js)
        s_s = find_threshold(p["weights"], debt, lambda r: r["senior_touched"], junior_share=js)
        s_u = find_threshold(p["weights"], debt, lambda r: r["unrec_pre"] > 0, junior_share=js, liquidate=False)
        f = lambda v: ("%.2f%%" % (v * 100)) if v is not None else "never"
        print("   %4.0f%%      |       %7s         |        %7s          |   %7s" % (js * 100, f(s_j), f(s_s), f(s_u)))
    # what does the FIRST liquidation slash at health just under 1?
    tr = build(p["weights"])
    r = walk(tr, debt, 0.3751)
    print("  at shock 37.51%% (health just < 1): maxLiquidatable = %s of $%.0fM debt, slash = %s; junior 5%% holds %s" % (
        "$%.1fM" % (r["liq"] / WAD / 1e6), debt / WAD / 1e6, "$%.1fM" % (sum(r["slashed"]) / WAD / 1e6),
        "$%.1fM" % (K0 * 0.05 * (1 - 0.3751) / WAD / 1e6)))


def section_n_tranches(p=DEFAULTS):
    print("\n== 3. 3-5 tranches (capital by weight), credit-util 100%: which tranches a single liquidation reaches ==")
    debt = int(K0 * (p["ltv"] / RAY))
    for weights in ([int(0.8e27), int(0.15e27), int(0.05e27)],
                    [int(0.7e27), int(0.15e27), int(0.1e27), int(0.05e27)],
                    [int(0.6e27), int(0.15e27), int(0.1e27), int(0.1e27), int(0.05e27)]):
        for shock in (0.40, 0.45, 0.48, 0.49, 0.50):
            tr = build(weights)
            r = walk(tr, debt, shock)
            print("  n=%d shock %.0f%%: liq %s slashed(senior..junior)=%s killed=%s h_post=%s unrec_post=%s" % (
                len(weights), shock * 100, "$%.1fM" % (r["liq"] / WAD / 1e6),
                ["$%.1fM" % (v / WAD / 1e6) for v in r["slashed"]], r["killed"], fmt_ray(r["h_post"], 3),
                "$%.2fM" % (r["unrec_post"] / WAD / 1e6)))


def section_leading_lagging(p=DEFAULTS):
    print("\n== 4. Is healthiness() leading or lagging real protection? ==")
    print("real protection = recoverableDebt / totalDebt = K / ((1+bonus) * debt); healthiness = K*lt/debt")
    print("healthiness == 1  <=>  K = debt/lt ;  protection == 1  <=>  K = debt*(1+bonus)")
    b = p["liquidationBonus"]
    for lt in (0.7, 0.8, 0.9, 0.95, 0.98, 0.9804, 0.99, 1.0):
        lt_ray = int(lt * RAY)
        # capital at which health = 1, and protection at that capital
        prot_at_h1 = (1 / lt) / (1 + b / RAY)
        cushion = 1 - (1 + b / RAY) * lt  # further price drop from health=1 to unrec>0
        lead = "LEADS by %.2f%% of price" % (cushion * 100) if cushion > 0 else "LAGS: unrec>0 while healthiness>=1"
        print("  lt %.4f bonus %.0f%%: protection at health=1 is %.4f; %s" % (lt, b / RAY * 100, prot_at_h1, lead))
    print("  threshold: healthiness lags real protection when lt > 1/(1+bonus) = %.4f (setLt permits up to 1.0)" % (1 / (1 + b / RAY)))
    print("  In the TIME dimension healthiness lags: premium accrues into debt every block with no price move,")
    print("  and a fixed borrow adds its whole-term premium instantly, so health moves before price does.")
    # numeric path: shock path in steps, compare health vs protection each step, prompt liquidation
    print("\n  Shock path (2 tranches 95/5, credit-util 100%), liquidator acts each step:")
    print("  step shock | health | protection | unrec | liq this step | cumulative slash | junior | senior")
    tr = build(p["weights"])
    debt = int(K0 * (p["ltv"] / RAY))
    cum = 0
    for shock in (0.10, 0.20, 0.30, 0.35, 0.375, 0.40, 0.45, 0.50, 0.55):
        price = P0 * (RAY - int(shock * RAY)) // RAY
        K = sum(t.capital(price) for t in tr)
        h = healthiness(K, debt, p["lt"])
        prot = min(1.0, K / ((1 + b / RAY) * debt)) if debt else 1.0
        unrec = unrecoverable_debt(K, debt, b)
        liq = 0
        if h < RAY:
            liq = max_liquidatable(K, debt, p["lt"], p["targetHealth"], b)
            toSlash = rayMul(liq, RAY + b)
            for i in range(len(tr) - 1, -1, -1):
                got = tr[i].slash(toSlash, price)
                cum += got
                toSlash -= got
                if toSlash == 0:
                    break
            debt -= liq
        print("  %5.1f%%     | %.3f  |   %.3f    | %s | %s | %s | %s | %s" % (
            shock * 100, h / RAY, prot, "$%.1fM" % (unrec / WAD / 1e6), "$%.1fM" % (liq / WAD / 1e6),
            "$%.1fM" % (cum / WAD / 1e6), "$%.1fM" % (tr[1].capital(price) / WAD / 1e6),
            "$%.1fM" % (tr[0].capital(price) / WAD / 1e6)))
    print("  With prompt liquidation at every step the path never reaches unrec>0: each liquidation resets health to")
    print("  targetHealth. The loss to cUSD holders needs a single JUMP (or liquidator absence) of size >= the cushion.")


if __name__ == "__main__":
    section_thresholds()
    section_junior_share()
    section_n_tranches()
    section_leading_lagging()
    p = DEFAULTS
    b = p["liquidationBonus"] / RAY
    print("\n=== HEADLINE ===")
    print("Defaults (lt 0.8, ltv 0.5, bonus 2%%, 95/5): at full credit-line draw, health<1 at a %.1f%% correlated price"
          " drop; cUSD holders take a loss (unrecoverableDebt>0) at %.1f%% if no liquidation lands in between."
          % ((1 - 0.5 / 0.8) * 100, (1 - 0.5 * (1 + b)) * 100))
    print("The 5% junior is wiped (and permanently KILLED) by the FIRST liquidation at any credit-util; the senior is touched in the same call:")
    print("restoring health from 1.0 to targetHealth 1.25 liquidates 58% of the debt in one call (perCleared = 1.25 - 1.02*0.8 = 0.434).")
    print("healthiness() LEADS unrecoverable debt by (1 - (1+bonus)*lt) = %.1f%% of price at defaults, but LAGS whenever"
          " lt > %.4f, which setLt permits (up to 1.0)." % ((1 - (1 + b) * 0.8) * 100, 1 / (1 + b)))
