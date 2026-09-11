#!/usr/bin/env python3
"""
reserve_decay.py - H1: minted yield erodes the reserve ratio; find utilization x rate x duration
at which the reserve can no longer service ordinary redemption demand.

Mechanics replicated (Stablecoin.sol, BaseMarket._chargePremium, FloatingMarket index):
  * Premium (liquidity + underwriter) is minted with mintCreditBacked: totalSupply += p and
    creditBackedSupply += p. NO underlying is added to the reserve. The reserve in underlying
    terms is therefore constant in absolute size while premium accrues unpaid.
  * reserve ratio  = unlockedSupply / totalSupply = (S - C - badDebt) / S.
  * Utilization u = C / S feeds the liquidity-rate curve (_nextLiquidityRate, exact int curve),
    times marketMultiplier. Underwriter premium adds a flat underwriterRate on the same debt.
  * Floating market: debt compounds via MathUtils.calculateCompoundedInterest (3-term binomial,
    exact replica) - we step daily and re-read the rate at the new utilization (the IRM re-prices
    the rate on every supply movement; daily is a conservative granularity).
  * Fixed market: whole-term premium is minted UP FRONT at borrow, so the reserve ratio jumps
    immediately by the term premium; we report that jump too.

Assumptions:
  * Initial supply S0 = $100M cUSD (results are scale-free in u; dollar figures shown for S0).
  * No bad debt at t=0; nobody repays until the "repayment" section.
  * Rate curve: base 5%, slope0 5%, slope1 10%, kink 80% (CapDeployer); marketMultiplier 1x and 2x;
    underwriterRate 20% (CapDeployer default) - shown as a total "carry" rate on the debt.
    (DeployInfra leaves the slopes at ZERO; with a 0% liquidity rate only the underwriter premium
    mints, so the 20% column is also the "production default until governance sets slopes" case.)
  * Redemption-demand assumption: ordinary daily redemption demand is DEMAND = 5% of totalSupply
    per day and must be serviceable INSTANTLY (i.e. reserve ratio >= 5%). Above that, redeemers
    fall into the FIFO queue (see run_dynamics.py).

Outputs:
  1. reserve ratio at day 0 / 30 / 90 / 365 across a grid of initial utilization x total rate.
  2. time-to-X% reserve (X = 20%, 10%, 5%, 1%) per cell.
  3. the initial utilization above which the reserve ratio drops below DEMAND within 30/90/365 d.
  4. repayment: the fraction of accruing premium that must be repaid (a) with cUSD bought from
     existing holders (supply burned) and (b) with fresh underlying deposited at par (reserve
     added) for the reserve ratio to stop falling. Derived analytically and checked by simulation.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import (RAY, WAD, DAY, SECONDS_PER_YEAR, rayMul, rayDiv, compounded_interest,
                     liquidity_rate_default, DEFAULTS, fmt_ray, vesting_weight)  # noqa: E402

S0 = 100_000_000 * WAD
DEMAND = 0.05  # 5% of supply per day must be instantly redeemable
UTILS = [0.20, 0.40, 0.60, 0.70, 0.80, 0.85, 0.90, 0.95]
# total carry on debt = liquidity rate(u) * mult + underwriterRate ; we sweep the fixed part
UW_RATES = [0.0, 0.05, 0.20]        # underwriter rate (no lower bound; CapDeployer default 20%)
MULTS = [1.0, 2.0]                  # marketMultiplier band [1, 2]
HORIZONS = [30, 90, 365]
TARGETS = [0.20, 0.10, 0.05, 0.01]


def total_rate(u_ray, mult, uw):
    """liquidity rate at u (exact curve) x multiplier + flat underwriter rate, in ray."""
    liq = rayMul(liquidity_rate_default(u_ray), int(mult * RAY))
    return liq + int(uw * RAY)


def simulate(u0, mult, uw, days=365, repay_frac=0.0, repay_via_deposit=False):
    """Daily stepping with the exact compounded-interest factor. Returns list of (day, S, C, R)."""
    C = S0 * int(round(u0 * 10000)) // 10000
    S = S0
    R = S0 - C  # reserve, 18dp
    out = [(0, S, C, R)]
    for d in range(1, days + 1):
        u = rayDiv(C, S) if S else 0
        r = total_rate(u, mult, uw)
        factor = compounded_interest(r, DAY)
        premium = rayMul(C, factor) - C
        # mint premium: credit-backed, no reserve
        S += premium
        C += premium
        if repay_frac > 0:
            rp = int(premium * repay_frac)
            if repay_via_deposit:
                # borrower deposits underlying at par (R += rp, S += rp) then burns (S -= rp, C -= rp)
                R += rp
                C -= rp
            else:
                # borrower buys cUSD from a holder and burns it: S -= rp, C -= rp, R unchanged
                S -= rp
                C -= rp
        out.append((d, S, C, R))
    return out


def ratio(S, C, R):
    return R / S


def simulate_optin(u0, mult, uw, f_opt, rho, days=3650, redeem_all_premium=False):
    """3dad5ef: the LIQUIDITY premium is fundCreditBacked -> minted to the Stablecoin's own pot and
    vested (12 h exponential) to opted-in cUSD holders (fraction f_opt of circulating balance).
    Each day: pot vests vesting_weight(DAY) = 86.5% of itself; opted-in holders claim it; a fraction
    rho of the claimed premium is redeemed INSTANTLY at par (R -= x, S -= x, C unchanged).
    Underwriter premium still goes to tranches (as in round 1); with redeem_all_premium it is also
    redeemed at rate rho (tranche depositors claim cUSD and redeem it - the same channel).
    Returns (day, S, C, R, opted_in_balance, other_balance, pot, cum_redeemed)."""
    C = S0 * int(round(u0 * 10000)) // 10000
    S = S0
    R = S0 - C
    circ = S0 - C  # circulating (non-credit) cUSD held by depositors = the reserve at t=0
    opt = int(circ * f_opt)
    oth = circ - opt
    pot = 0
    cum = 0
    w_day = vesting_weight(DAY)
    out = [(0, S, C, R, opt, oth, pot, cum)]
    for d in range(1, days + 1):
        u = rayDiv(C, S) if S else 0
        liq = rayMul(rayMul(C, compounded_interest(rayMul(liquidity_rate_default(u), int(mult * RAY)), DAY)) - C, RAY)
        uwp = rayMul(C, compounded_interest(int(uw * RAY), DAY)) - C
        S += liq + uwp
        C += liq + uwp
        pot += liq
        vested_today = pot * w_day // RAY if f_opt > 0 else 0  # staked == 0 freezes the pot
        pot -= vested_today
        opt += vested_today
        redeem = int(vested_today * rho) + (int(uwp * rho) if redeem_all_premium else 0)
        if redeem > R:
            redeem = R
        R -= redeem
        S -= redeem
        opt -= min(opt, int(vested_today * rho))
        cum += redeem
        out.append((d, S, C, R, opt, oth, pot, cum))
    return out


def time_to(path, target):
    for d, S, C, R in path:
        if ratio(S, C, R) < target:
            return d
    return None


def fmt_t(t):
    if t is None:
        return "-"
    if t >= 365:
        return "%.1fy" % (t / 365)
    return "%dd" % t


def main():
    print("reserve_decay.py  S0=$100M  demand assumption: %.0f%% of supply/day instantly redeemable" % (DEMAND * 100))
    print("rate curve base 5%% slope0 5%% slope1 10%% kink 80%%; underwriter rate and multiplier swept\n")

    print("== 1. Reserve ratio (R/S) over time, no repayments ==")
    hdr = "u0    uw    mult | rate@u0  | day0   day30  day90  day365 | t->20%  t->10%   t->5%   t->1%   (10y horizon)"
    print(hdr)
    crit = {}  # (uw, mult, horizon) -> lowest u0 whose ratio < DEMAND within horizon
    for uw in UW_RATES:
        for mult in MULTS:
            for u0 in UTILS:
                path = simulate(u0, mult, uw, days=3650)
                r0 = total_rate(int(u0 * RAY), mult, uw)
                ratios = [ratio(*path[d][1:]) for d in (0, 30, 90, 365)]
                tt = [time_to(path, t) for t in TARGETS]
                print("%.2f  %.2f  %.1f  | %6.2f%%  | %.3f  %.3f  %.3f  %.3f  | %s" % (
                    u0, uw, mult, r0 / RAY * 100, *ratios,
                    "  ".join("%6s" % fmt_t(t) for t in tt)))
                for h in HORIZONS:
                    if ratio(*path[h][1:]) < DEMAND:
                        key = (uw, mult, h)
                        if key not in crit or u0 < crit[key]:
                            crit[key] = u0
            print()

    print("== 2. Critical initial utilization: reserve ratio < %.0f%% within horizon (no repayment) ==" % (DEMAND * 100))
    print("uw     mult | 30d     90d     365d   (lowest grid u0 that breaches; '-' = none up to 0.95)")
    for uw in UW_RATES:
        for mult in MULTS:
            row = []
            for h in HORIZONS:
                v = crit.get((uw, mult, h))
                row.append("%.2f" % v if v is not None else "-")
            print("%.2f   %.1f  | %s" % (uw, mult, "    ".join("%-5s" % x for x in row)))

    # finer search of exact threshold for the default config (uw 20%, mult 1)
    print("\n== 2b. Exact threshold search (uw 20%%, mult 1x): smallest u0 breaching %.0f%% ==" % (DEMAND * 100))
    for h in HORIZONS:
        lo, hi = 0.0, 0.95
        for _ in range(30):
            mid = (lo + hi) / 2
            path = simulate(mid, 1.0, 0.20, days=h)
            if ratio(*path[h][1:]) < DEMAND:
                hi = mid
            else:
                lo = mid
        print("  within %3dd: u0 >= %.4f   (day-0 reserve %.2f%% -> %.2f%%)" % (
            h, hi, (1 - hi) * 100, ratio(*simulate(hi, 1.0, 0.20, days=h)[h][1:]) * 100))

    print("\n== 3. Fixed market: whole-term premium minted at borrow (instant reserve hit) ==")
    for term_days in (1, 7, 30):
        for u0 in (0.5, 0.8, 0.9):
            C = int(S0 * u0)
            # a borrow of size L at utilization u0: premium = L * term * rate(u after mint)/year
            L = S0 // 10  # $10M borrow
            u_after = rayDiv(C + L, S0 + L)
            r = total_rate(u_after, 1.0, 0.20)
            prem = rayMul(L * term_days * DAY, r) // SECONDS_PER_YEAR
            before = (S0 - C) / S0
            after = (S0 - C) / (S0 + L + prem)
            print("  term %2dd u0 %.2f: $10M borrow mints %s premium up front; reserve ratio %.4f -> %.4f" % (
                term_days, u0, "$%.0fk" % (prem / WAD / 1e3), before, after))

    print("\n== 4. Repayment: fraction f of accruing premium repaid; does the reserve ratio stabilise? ==")
    print("Analytic: (a) repaid with cUSD bought from holders (S burns, R fixed): d(R/S)/dt = -R p (1-f)/S^2 < 0 for all f < 1")
    print("          => stabilises ONLY at f = 1 (every wei of premium repaid as it accrues).")
    print("          (b) repaid with fresh underlying deposited at par (R += f p): d(R/S)/dt = p (f S - R)/S^2")
    print("          => stabilises when f >= R/S = current reserve ratio = (1 - u).")
    print("Simulation check, u0 0.80, uw 20%, mult 1x, 365 days:")
    for f in (0.0, 0.10, 0.19, 0.20, 0.21, 0.5, 1.0):
        pa = simulate(0.80, 1.0, 0.20, repay_frac=f, repay_via_deposit=False)
        pb = simulate(0.80, 1.0, 0.20, repay_frac=f, repay_via_deposit=True)
        print("  f=%.2f  (a) buy-and-burn: %.4f -> %.4f   (b) deposit-and-burn: %.4f -> %.4f" % (
            f, ratio(*pa[0][1:]), ratio(*pa[365][1:]), ratio(*pb[0][1:]), ratio(*pb[365][1:])))

    print("\n== 5. v2 DELTA (3dad5ef): liquidity premium vests to OPTED-IN cUSD holders (was stcUSD) ==")
    print("Reserve identity unchanged: premium is minted credit-backed either way, so with rho = 0 the R/S path is")
    print("byte-identical to section 1 for every opt-in fraction f (the pot is a cUSD balance of the Stablecoin).")
    print("What changed: the premium lands in the SAME token, so an opted-in holder can claim and redeem it against")
    print("the reserve in one hop. rho = fraction of vested premium redeemed at par the day it vests.")
    print("u0 0.80, uw 20%, mult 1x. Columns: R/S at 1y, unlocked/total at 1y, time to R/S < 5%, opted-in APY, non-opted-in share erosion")
    base = simulate(0.80, 1.0, 0.20, days=3650)
    print("  round-1 baseline (no redemption):        R/S 1y %.4f  t->5%% %s" % (ratio(*base[365][1:]), fmt_t(time_to(base, 0.05))))
    for f in (0.10, 0.50, 1.00):
        for rho in (0.0, 0.5, 1.0):
            pth = simulate_optin(0.80, 1.0, 0.20, f, rho)
            d, S, C, R, opt, oth, pot, cum = pth[365]
            r1y = R / S
            tt = None
            for row_ in pth:
                if row_[3] / row_[1] < 0.05:
                    tt = row_[0]; break
            # opted-in APY on the liquidity premium: liq premium in year 1 / opted-in balance at t=0
            liq_year = sum(pth[i][6] - pth[i - 1][6] for i in range(1, 366)) + sum(
                (pth[i][4] - pth[i - 1][4]) for i in range(1, 366)) if f > 0 else 0
            opt0 = pth[0][4]
            # simpler: total liquidity premium minted in year 1 = pot inflow; recompute directly
            inflow = 0
            for i in range(1, 366):
                Sp, Cp = pth[i - 1][1], pth[i - 1][2]
                u = rayDiv(Cp, Sp)
                inflow += rayMul(Cp, compounded_interest(liquidity_rate_default(u), DAY)) - Cp
            apy = inflow / opt0 * 100 if opt0 else 0
            share0 = pth[0][5] / pth[0][1]
            share1 = pth[365][5] / pth[365][1]
            erosion = ("non-opted share %.4f -> %.4f (-%.1f%%)" % (share0, share1, (1 - share1 / share0) * 100)) if share0 > 0 else "non-opted share: n/a (all opted in)"
            print("  f=%.2f rho=%.1f: R/S 1y %.4f  t->5%% %6s  redeemed 1y $%.1fM  opted-in liq APY %6.1f%%  %s" % (
                f, rho, r1y, fmt_t(tt), cum / WAD / 1e6, apy, erosion))
    print("  (also redeeming the underwriter premium, rho=1, f=1):")
    pth = simulate_optin(0.80, 1.0, 0.20, 1.0, 1.0, redeem_all_premium=True)
    tt = next((r_[0] for r_ in pth if r_[3] / r_[1] < 0.05), None)
    print("   R/S 1y %.4f  t->5%% %s  redeemed 1y $%.1fM" % (pth[365][3] / pth[365][1], fmt_t(tt), pth[365][7] / WAD / 1e6))
    print("  Reading: f does not move the system ratio at all (the pot goes to whoever opted in; only f = 0 freezes it).")
    print("  rho > 0 shortens the clock because redeeming premium drains R while S falls by the same amount and R < S.")
    print("  This channel also existed in round 1 (stcUSD -> cUSD -> redeem) and was not modelled there; it is not new")
    print("  supply, it is the existing premium being cashed against the reserve sooner. The per-holder effect is the")
    print("  real delta: a non-opted-in holder's share of supply erodes by the full liquidity carry every year.")
    print("  APY is on the opted-in DEPOSITOR balance (f x $20M); if holders of the $80M credit-backed cUSD also opt in,")
    print("  divide by up to 5 - the pot is split over `staked`, whoever that is; borrowers can opt in their own draw.")

    print("\n=== HEADLINE ===")
    p = simulate(0.80, 1.0, 0.20)
    p = simulate(0.80, 1.0, 0.20, days=3650)
    print("Default config (u0 80%%, carry %.1f%%): reserve 20%% -> %.1f%% after 1y with no repayment; "
          "first < 5%% after %s." % (total_rate(int(0.8 * RAY), 1.0, 0.20) / RAY * 100,
                                   ratio(*p[365][1:]) * 100, fmt_t(time_to(p, 0.05))))
    p = simulate(0.90, 1.0, 0.20, days=3650)
    print("u0 90%%: reserve 10%% -> %.1f%% after 1y; first < 5%% after %s." % (ratio(*p[365][1:]) * 100, fmt_t(time_to(p, 0.05))))
    print("The decay is SLOW (months to years) at realistic carry: H1 is a solvency clock, not a cliff. The real")
    print("exposure is the one-shot fixed-market premium and the compounding at u > 90% where carry exceeds 35%.")
    print("Reserve ratio stabilises only if borrowers repay >= (1-u) of accruing premium with FRESH deposits, "
          "or 100% of it with existing cUSD. Nothing in the protocol enforces either; the clock runs by design.")
    pth = simulate_optin(0.80, 1.0, 0.20, 1.0, 1.0)
    tt = next((r_[0] for r_ in pth if r_[3] / r_[1] < 0.05), None)
    print("v2 delta: opt-in fraction does not change the R/S path; if opted-in holders redeem every vested liquidity")
    print("premium at par the day it vests, R/S at 1y is %.1f%% (vs %.1f%%) and the < 5%% clock moves from %s to %s." % (
        pth[365][3] / pth[365][1] * 100, ratio(*p[365][1:]) * 100, fmt_t(time_to(p, 0.05)), fmt_t(tt)))


if __name__ == "__main__":
    main()
