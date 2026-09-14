#!/usr/bin/env python3
"""
premium_accrual_insolvent.py - P9: after unrecoverableDebt > 0, the permissionless
FloatingMarket.chargePremium (L99-101) and KEEPER extendAdmin (FixedMarket L113-124) keep minting
premium. Every wei is credit-backed supply owed by a debt that can no longer be recovered, so all
of it becomes bad debt at writeOff (FloatingMarket.writeOff L104-113 clears unrecoverableDebt AT
THAT TIME, i.e. including the premium accrued during the delay). HEAD a843c1d.

Where it goes (BaseMarket._chargePremium L435-475): liquidity leg -> Stablecoin.fundCreditBacked
(vests to opted-in cUSD, i.e. stcUSD); underwriter leg -> tranches that pass _earnsPremium
(stakedSupply > 0 AND totalCapital > 0, L482-485); an ineligible junior's weight goes to the
senior, and if no tranche is eligible the whole underwriter leg vests on the stablecoin - cUSD
holders are paid with their own future write-off.

Scenario: floating market D = $50M, collateral collapsed to K = $30.6M (recoverable $30M,
unrecoverableDebt $20M) and no liquidator/guardian action. cUSD S = $100M, u = 50%: harness
curve gives 8.125% liquidity; underwriter 20%. Hourly stepping with the exact index math
(MathUtils binomial per hour, IRM re-rated from the growing u). Junior wiped (capital 0),
senior alive - and the alternative where both tranches are empty.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, HOUR, DAY, SECONDS_PER_YEAR, rayMul, rayDiv, compounded_interest, liquidity_rate_default,  # noqa: E402
                     charge_underwriter_premium, DEFAULTS)

S0 = 100_000_000 * WAD
D0 = 50_000_000 * WAD
K = 30_600_000 * WAD
UW = int(0.2e27)


def simulate(days, earns=(True, False), uw=UW):
    S, C, debt = S0, D0, D0
    liq_tot, uw_tot, to_tr = 0, 0, [0, 0]
    to_stable_uw = 0
    for _ in range(days * 24):
        u = rayDiv(C, S)
        r = liquidity_rate_default(u)
        fl, fu = compounded_interest(r, HOUR), compounded_interest(uw, HOUR)
        after_liq = rayMul(debt, fl)
        liq = after_liq - debt
        uwp = rayMul(after_liq, fu) - after_liq
        debt = rayMul(after_liq, fu)
        S += liq + uwp
        C += liq + uwp
        liq_tot += liq
        uw_tot += uwp
        split, st = charge_underwriter_premium(uwp, DEFAULTS["weights"], list(earns))
        to_tr[0] += split[0]
        to_tr[1] += split[1]
        to_stable_uw += st
    return dict(debt=debt, liq=liq_tot, uw=uw_tot, senior=to_tr[0], junior=to_tr[1], stable_uw=to_stable_uw, S=S, C=C)


def main():
    b = DEFAULTS["liquidationBonus"]
    rec = rayDiv(K, RAY + b)
    unrec0 = D0 - rec
    print("premium_accrual_insolvent.py  HEAD a843c1d  D=$50M, K=$30.6M -> recoverable $%.1fM, unrecoverable $%.1fM at t=0; S=$100M\n" % (
        rec / WAD / 1e6, unrec0 / WAD / 1e6))
    print("== 1. Unbacked premium minted per day of GUARDIAN delay (junior wiped, senior still earning) ==")
    print("  delay | debt      | extra bad debt | per day  | liquidity leg -> stcUSD | uw leg -> senior | -> junior | total bad debt at writeOff | +% | badDebt/S")
    prev = 0
    for days in (1, 7, 30, 90, 180, 365):
        r = simulate(days)
        extra = r["debt"] - D0
        print("  %4dd | $%6.2fM  |   $%6.3fM     | $%6.0f  |        $%6.3fM         |     $%6.3fM     |  $%5.3fM  |          $%6.2fM           | %4.1f%% | %5.2f%%" % (
            days, r["debt"] / WAD / 1e6, extra / WAD / 1e6, extra / WAD / days, r["liq"] / WAD / 1e6, r["senior"] / WAD / 1e6,
            r["junior"] / WAD / 1e6, (unrec0 + extra) / WAD / 1e6, extra * 100 / unrec0, (unrec0 + extra) * 100 / r["S"]))
    print("  The senior tranche, which is about to be slashed to zero, is paid 20%/yr on the whole $50M out of cUSD that will be written off.")

    print("\n== 2. Both tranches empty (K=0 after a full slash, debt residual unrecoverable): _earnsPremium false for all ==")
    for days in (30, 365):
        r = simulate(days, earns=(False, False))
        print("  %4dd: liquidity $%.3fM + underwriter $%.3fM = $%.3fM ALL vested on the stablecoin: opted-in cUSD holders receive their own future loss" % (
            days, r["liq"] / WAD / 1e6, r["stable_uw"] / WAD / 1e6, (r["liq"] + r["stable_uw"]) / WAD / 1e6))

    print("\n== 3. Sensitivity: underwriter rate x delay -> extra bad debt as % of the initial $20M ==")
    print("  uw rate | 7d     | 30d    | 90d    | 365d")
    for uw in (0.0, 0.05, 0.2, 0.5, 1.0):
        row = []
        for days in (7, 30, 90, 365):
            r = simulate(days, uw=int(uw * RAY))
            row.append("%5.1f%%" % ((r["debt"] - D0) * 100 / unrec0))
        print("  %5.0f%%   | %s" % (uw * 100, " | ".join(row)))

    print("\n== 4. Fixed market equivalent: each KEEPER extendAdmin roll after insolvency adds a whole term of premium at once ==")
    for term_d in (1, 7, 30):
        prem = D0 * term_d * DAY // SECONDS_PER_YEAR * (int(0.08125e27) + UW) // RAY
        print("  roll of %2d d on $50M: +$%.3fM of bad debt per roll (%.2f%% of the initial unrecoverable)" % (term_d, prem / WAD / 1e6, prem * 100 / unrec0))

    print("\n=== HEADLINE ===")
    r30, r365 = simulate(30), simulate(365)
    print("With $20M unrecoverable on a $50M floating debt, every day without writeOff mints ~$%.0f of unbacked cUSD (28%%/yr carry): $%.2fM after" % (
        (r30["debt"] - D0) / WAD / 30, (r30["debt"] - D0) / WAD / 1e6))
    print("30 days (+%.1f%% bad debt), $%.2fM after a year (+%.0f%%), %.0f%% of it to stcUSD holders and %.0f%% to the senior tranche that is about to be" % (
        (r30["debt"] - D0) * 100 / unrec0, (r365["debt"] - D0) / WAD / 1e6, (r365["debt"] - D0) * 100 / unrec0,
        r365["liq"] * 100 / (r365["debt"] - D0), r365["senior"] * 100 / (r365["debt"] - D0)))
    print("slashed. Nothing on-chain stops it: chargePremium is permissionless and has no health or recoverability check.")


if __name__ == "__main__":
    main()
