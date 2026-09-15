#!/usr/bin/env python3
"""
rate_sweep.py - rates across utilization; where the rational move harms the system. HEAD a843c1d.

Exact pieces (capmath): IRM._nextLiquidityRate (curve), IRM._index / MathUtils binomial (global
liquidity index, one update per hour assumed - the IRM re-indexes on every supply movement),
FloatingMarket._growIndex (multiplier is an EXPONENT on the global growth factor: local = G^m,
L195-202), FixedMarket._ratesStillToMint (multiplier is LINEAR on the fixed leg: rate * m, L262),
IRM.termMultiplier, FixedMarket._borrowPremium (incremental in global unsmoothedCredit, L337-351),
IRM.averageUtilizationAfterMint (HEAD rule: unabsorbed credit added to both sides, L227-239).

No deploy script sets liquidity slopes, a term-multiplier slope, an underwriter rate or an ltv
(DeployInfra L88-93 initialises the IRM band only): production starts at a 0% liquidity rate.
The HARNESS curve (base 5% / slope0 5% / slope1 10% / kink 80%, CapDeployer L131-132, applied only
when applyLiquiditySlopes is true) is used as the intended shape and a steeper alternative is swept.

Protocol take: BaseMarket._chargePremium L438-441 sends the liquidity premium to
Stablecoin.fundCreditBacked (vests to opted-in cUSD holders, PremiumVesting) and L455-473 the
underwriter premium to tranches (or the senior, or the stablecoin). There is no fee recipient,
treasury or protocol share anywhere in the premium path: protocol take = 0. Stated, not modelled.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, HOUR, DAY, SECONDS_PER_YEAR, rayMul, rayDiv, compounded_interest, ray_pow_ray,  # noqa: E402
                     next_liquidity_rate, liquidity_rate_default, term_multiplier, fixed_premium, borrow_premium,
                     UtilizationAverage, DEFAULTS)

S = 100_000_000 * WAD
ALT = dict(base=int(0.02e27), slope0=int(0.08e27), slope1=int(0.50e27), kink=int(0.90e27))


def annual_growth(rate, updates=24 * 365):
    """Global liquidity index after one year with `updates` equally spaced re-indexings."""
    g = RAY
    f = compounded_interest(rate, SECONDS_PER_YEAR // updates)
    for _ in range(updates):
        g = rayMul(g, f)
    return g


def section_rates():
    print("== 1. Liquidity rate and floating borrower cost across cUSD utilization u (hourly re-indexing) ==")
    print("  u    | r(u) harness | r(u) alt curve | float m=1 | float m=1.5 | float m=2 (G^m-1) | linear m*r @2 | gap @2 | fixed leg m=2 (linear)")
    for u in (0.0, 0.2, 0.4, 0.6, 0.8, 0.85, 0.9, 0.95, 1.0):
        r = liquidity_rate_default(int(u * RAY))
        ra = next_liquidity_rate(int(u * RAY), ALT["base"], ALT["slope0"], ALT["slope1"], ALT["kink"])
        G = annual_growth(r)
        c = [ray_pow_ray(G, m) - RAY for m in (RAY, int(1.5e27), 2 * RAY)]
        print("  %.2f | %8.2f%%    |    %6.2f%%     |  %6.2f%%  |   %6.2f%%   |     %6.2f%%       |    %6.2f%%    | %+5.2f%% |   %6.2f%%" % (
            u, r / RAY * 100, ra / RAY * 100, c[0] / RAY * 100, c[1] / RAY * 100, c[2] / RAY * 100,
            2 * r / RAY * 100, (c[2] - 2 * r) / RAY * 100, 2 * r / RAY * 100))
    print("  Exponent semantics: m=2 squares the growth factor, so a floating borrower pays (1+r)^2-1 = 2r + r^2 (+compounding), the")
    print("  fixed market charges 2r linearly (FixedMarket L262). The gap grows with r: it is the region where floating > fixed at equal m.")


def section_lender():
    print("\n== 2. Lender (stcUSD) yield = liquidity premium / opted-in supply; opt-in fraction phi of TOTAL supply ==")
    print("  Only opted-in balances earn (PremiumVesting L15). Premium = r(u) * C per year (m=1); yield per staked cUSD = r(u)*u/phi.")
    print("  u    | r(u)   | phi=1.0 | phi=0.5 | phi=0.25 | phi=0.1 | underwriter rate (owner-set, flat, 0..100%) | protocol take")
    for u in (0.2, 0.5, 0.8, 0.9, 0.95):
        r = liquidity_rate_default(int(u * RAY)) / RAY
        print("  %.2f | %5.2f%% | %6.2f%% | %6.2f%% |  %6.2f%% | %6.2f%% |        not a function of u                  |    0" % (
            u, r * 100, r * u * 100, r * u / 0.5 * 100, r * u / 0.25 * 100, r * u / 0.1 * 100))


def section_term():
    print("\n== 3. Fixed term multiplier 1 + slope*(1 - term/maxTerm) (max term 30 d; slope UNBOUNDED, setTermMultiplierSlope) ==")
    print("  slope | 1d     | 7d     | 15d    | 30d   (multiplier on the liquidity leg; never below 1, never negative)")
    for slope in (0, 0.5, 1.0, 5.0, 50.0):
        row = [term_multiplier(rayDiv(t * DAY, 30 * DAY), int(slope * RAY)) / RAY for t in (1, 7, 15, 30)]
        print("  %5.1f | %6.2f | %6.2f | %6.2f | %6.2f" % (slope, *row))


def section_underwriter():
    print("\n== 4. Underwriter EV per $1 of tranche capital at leverage L = D/K = ltv = 0.5; where the rational move harms the system ==")
    b = DEFAULTS["liquidationBonus"] / RAY
    print("  net = uw*L - p_def*(1+b)*L - p_vol*0.58*(1+b)*L   (0.58 = first-liquidation share of debt at TH 1.25, lt 0.8)")
    print("  break-even uw rate (independent of L): p_def 1%%: %.2f%%  2%%: %.2f%%  5%%: %.2f%%  (+0.58(1+b)p_vol)" % (
        0.01 * (1 + b) * 100, 0.02 * (1 + b) * 100, 0.05 * (1 + b) * 100))
    print("  The underwriter rate is set by the MARKET OWNER (borrowing side), floor 0, and does not move with u, vol or health.")
    print("  Exit window (Tranche.unlockedSupply, lockedValue = D/(lt-buffer) = D/0.7 on the SENIOR after the junior):")
    for d in (0.0, 0.1, 0.2, 0.25, 0.286, 0.3):
        K = 1 - d
        locked = 0.5 / 0.7 - 0.05 * K          # senior's locked USD per $1 K0
        free = max(0.0, 0.95 * K - locked) / (0.95 * K)
        print("    drawdown %5.1f%%: health %.3f, senior capital free to exit %5.1f%%" % (d * 100, 0.8 * K / 0.5, free * 100))
    print("  => a senior underwriter can pull ~30% of capital until the price has fallen 28.6% (health 1.14), i.e. BEFORE liquidation")
    print("     is possible (37.5%) and while its EV is most negative. The junior is 100% locked from a 7% draw onwards.")

    print("\n  Floating vs fixed at equal m and u (annual cost; fixed rolled every 30 d; uw 20%):")
    print("  u    | m   | floating (1+r)^m*(1+uw)-1 | fixed rolled monthly | migrate to fixed?")
    for u in (0.8, 0.9, 1.0):
        r = liquidity_rate_default(int(u * RAY))
        G = annual_growth(r)
        U = annual_growth(int(0.2e27))
        for m in (1.0, 1.5, 2.0):
            fl = rayMul(ray_pow_ray(G, int(m * RAY)), U) - RAY
            per = 1 + (m * r / RAY + 0.2) * 30 * DAY / SECONDS_PER_YEAR
            fx = per ** (365 / 30) - 1
            print("  %.2f | %.1f |          %6.2f%%           |       %6.2f%%        | %s" % (
                u, m, fl / RAY * 100, fx * 100, "yes (%+.2f%%)" % ((fl / RAY - fx) * 100) if fl / RAY > fx else "no"))


def section_p8():
    print("\n== 5. P8: borrower opts in on cUSD (PremiumVesting.optIn is public, L114) and captures D/(staked+D) of every liquidity premium ==")
    print("  S=$100M, credit C=uS, non-borrower holders opt in a fraction phi of (S-C); new borrower D parks the loan opted-in.")
    print("  earn = D/(phi(S-C)+D) * r' (C+D); cost = (r' + uw) D  [r' at u after mint]. Liquidity leg free when C >= phi (S-C), i.e. u >= phi/(1+phi).")
    print("  u    | phi  | D      | D/staked | net liquidity cost | net cost incl. uw 20% | share of pool captured")
    for u in (0.5, 0.8, 0.9):
        for phi in (1.0, 0.5):
            for D in (5_000_000 * WAD, 20_000_000 * WAD):
                C = int(S * u)
                staked = int(phi * (S - C))
                r2 = liquidity_rate_default(rayDiv(C + D, S + D)) / RAY
                earn = D / (staked + D) * r2 * (C + D)
                net_liq = r2 * D - earn
                net_all = net_liq + 0.2 * D
                print("  %.2f | %.2f | $%3.0fM |  %6.2f  |   %+7.2f%% of D      |      %+7.2f%% of D      |   %5.1f%%" % (
                    u, phi, D / WAD / 1e6, D / staked, net_liq / D * 100, net_all / D * 100, D / (staked + D) * 100))
    print("  Threshold: liquidity leg free at u >= 50% (phi=1) / 33% (phi=0.5); ALL-IN free (incl. uw) when (C+D)/(staked+D) >= 1 + uw/r'.")
    print("  General form: yield to stakers r*u/phi_T (phi_T = staked/TOTAL supply) vs borrower all-in cost r+uw: borrow-to-stake is a")
    print("  money pump while phi_T < u/(1+uw/r); it self-limits at phi* where lender yield == borrower cost.")
    print("  u    | r(u)   | uw  | phi* = u/(1+uw/r) | staker yield at phi* | borrower cost | loop profitable while staked/S <")
    for u in (0.5, 0.8, 0.9, 0.95):
        for uw in (0.0, 0.05, 0.2):
            r2 = liquidity_rate_default(int(u * RAY)) / RAY
            phi = u / (1 + uw / r2)
            print("  %.2f | %5.2f%% | %3.0f%% |       %5.3f        |       %6.2f%%        |    %6.2f%%    |   %5.1f%%" % (
                u, r2 * 100, uw * 100, phi, r2 * u / phi * 100, (r2 + uw) * 100, phi * 100))


def section_p6():
    print("\n== 6. P6: fixed _borrowPremium is incremental in GLOBAL unsmoothedCredit: a same-window floating borrow C makes a fixed draw P pay C*term*(r_P - r_0) ==")
    print("  S=$100M, harness curve, averaging 1 h, EMA quiet before; floating C at t=0, fixed P=$10M at t; uw leg unaffected (flat).")
    print("  u0   | C/P | t     | r_0     | r_P     | fixed's own premium (30d) | overcharge (30d) | % of own | overcharge 7d | 1d")
    P = 10_000_000 * WAD
    for u0 in (0.8, 0.9):
        C0 = int(S * u0)
        for cp in (0.5, 1, 2, 5):
            C = int(P * cp)
            for t in (0, 15 * 60, HOUR):
                ema = UtilizationAverage(0, HOUR)
                ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C0, S, C0, S
                ema.accrue(0, C0 + C, S + C)              # floating borrow minted at t=0
                live = C0 + C
                prior = ema.unsmoothed_credit(t, live)
                u_after = ema.average_utilization_after_mint(t, live, P)
                u_before = ema.average_utilization_after_mint(t, live, 0)
                rP, r0 = liquidity_rate_default(u_after), liquidity_rate_default(u_before)
                out = []
                for term in (30 * DAY, 7 * DAY, DAY):
                    liq, _ = borrow_premium(prior, P, term, rP, r0, 0)
                    own, _ = fixed_premium(P, term, rP, 0)
                    out.append((liq - own, own))
                print("  %.2f | %3.1f | %5s | %6.3f%% | %6.3f%% |        $%9.0f         |    $%8.0f     |  %5.2f%%  |   $%7.0f    | $%5.0f" % (
                    u0, cp, ("%dm" % (t // 60)) if t < HOUR else "1h", r0 / RAY * 100, rP / RAY * 100, out[0][1] / WAD,
                    out[0][0] / WAD, out[0][0] * 100 / out[0][1], out[1][0] / WAD, out[2][0] / WAD))
    print("  The floating borrower C pays nothing extra (its rate is the live one); the overcharge is pure, decays as e^(-t/period), and is")
    print("  paid to opted-in cUSD holders. Same-block floating borrow+repay (C in, C out) leaves prior = 0: no overcharge, but also no charge.")


if __name__ == "__main__":
    print("rate_sweep.py  HEAD a843c1d  harness curve 5/5/10/kink 80 (no deploy slopes exist); alt curve 2/8/50/kink 90; bonus 2%; ltv 0.5\n")
    section_rates()
    section_lender()
    section_term()
    section_underwriter()
    section_p8()
    section_p6()
    print("\n=== HEADLINE ===")
    G1 = annual_growth(liquidity_rate_default(RAY))
    print("Multiplier is an exponent on floating (G^m) and linear on fixed (m*r): at u=1, m=2 floating pays %.2f%%/yr vs 40%% fixed (+%.2f pts);" % (
        (ray_pow_ray(G1, 2 * RAY) - RAY) / RAY * 100, (ray_pow_ray(G1, 2 * RAY) - RAY) / RAY * 100 - 40))
    print("floating > fixed rolled monthly at every (u, m) tested (+0.5 to +2.6 pts), so borrowers migrate to fixed (EMA-priced, M-2). Protocol take: 0.")
    r8 = liquidity_rate_default(int(0.8 * RAY)) / RAY
    ema = UtilizationAverage(0, HOUR); C0 = int(S * 0.8); C = 50_000_000 * WAD; P = 10_000_000 * WAD
    ema.credit, ema.supply, ema.observedCredit, ema.observedSupply = C0, S, C0, S
    ema.accrue(0, C0 + C, S + C)
    rP, r0 = liquidity_rate_default(ema.average_utilization_after_mint(0, C0 + C, P)), liquidity_rate_default(ema.average_utilization_after_mint(0, C0 + C, 0))
    liq, _ = borrow_premium(C, P, 30 * DAY, rP, r0, 0); own, _ = fixed_premium(P, 30 * DAY, rP, 0)
    print("P8: borrow-to-stake is a money pump while staked/S < u/(1+uw/r) = %.1f%% at u=0.8 (harness r=10%%, uw 20%%), %.1f%% at uw=5%%; with full" % (
        0.8 / (1 + 0.2 / r8) * 100, 0.8 / (1 + 0.05 / r8) * 100))
    print("opt-in the liquidity leg alone is free from u >= 50%%. P6: a $10M 30d fixed draw after a same-block $50M floating borrow is overcharged $%.0f (%.1f%% of its own premium) at u=0.8." % (
        (liq - own) / WAD, (liq - own) * 100 / own))
    print("Underwriting is negative-EV below uw = (1+b)(p_def + 0.58 p_vol) = 2.04% at 2%/yr default risk; the senior can exit 30% of capital")
    print("until the price has fallen 28.6%, before liquidation is possible at 37.5%: the rational exit precedes the loss it was meant to cover.")
