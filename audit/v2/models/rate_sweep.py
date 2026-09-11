#!/usr/bin/env python3
"""
rate_sweep.py - H8: lender yield vs underwriter premium vs protocol take across utilization, and
the region where underwriting has NEGATIVE expected value.

Exact pieces (capmath): _nextLiquidityRate curve (base 5%, slope0 5%, slope1 10%, kink 80%),
marketMultiplier band [1x, 2x], underwriterRate in [0, maximumUnderwriterRate=100%] with NO
lower bound (InterestRateModel.updateUnderwriterRate: "a market may set its underwriter rate to
zero"), set by the MARKET OWNER role (Registry._configureMarketRoles: setUnderwriterRate is an
ownerSelector) - i.e. the borrowing side prices its own guarantee.

Protocol take: BaseMarket._chargePremium mints the liquidity premium to stakedStablecoin and the
underwriter premium to tranches (leftover to senior / stakedStablecoin). There is NO protocol fee
anywhere in the premium path. We say so and model zero.

Per unit of TRANCHE CAPITAL (K), with the credit line drawn to leverage L = debt/K <= ltv:
  underwriter gross yield  = underwriterRate * L
  expected loss            = p_default * L * (1 + bonus) * LGD           (borrower default: the whole
                             covered debt is cleared by slashing (1+bonus) of collateral; the
                             underwriter's only recourse is off-chain)
                           + p_vol_liq * E[slash | vol-triggered liquidation]  (collateral-price
                             liquidation with a PERFORMING borrower who does not top up: from
                             solvency_waterfall, the first liquidation at health=1 slashes
                             0.58*(1+bonus)*debt at TH 1.25)
  net = gross - expected loss.  Break-even underwriterRate* = expected loss / L.

Per unit of cUSD supply at utilization u: lender yield = liquidityRate(u) * mult * u (all of the
liquidity premium goes to stakedStablecoin; if only a fraction f of cUSD is staked, the staker's
yield is that divided by f).

Assumptions: p_default swept {1%, 2%, 5%, 10%}/yr, LGD = 1 (unsecured covered credit), bonus 2%,
p_vol_liq = P(ETH falls 37.5% within a year without the borrower curing) swept {0, 5%, 15%}.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import RAY, WAD, rayMul, liquidity_rate_default, DEFAULTS  # noqa: E402

UTILS = [0.0, 0.2, 0.4, 0.6, 0.8, 0.85, 0.9, 0.95, 1.0]
P_DEF = [0.01, 0.02, 0.05, 0.10]
P_VOL = [0.0, 0.05, 0.15]
FIRST_LIQ_FRAC = 0.58  # from solvency_waterfall: (TH-1)/(TH-(1+b)lt) at defaults


def main():
    p = DEFAULTS
    b = p["liquidationBonus"] / RAY
    ltv = p["ltv"] / RAY
    print("rate_sweep.py  curve base 5%/slope0 5%/slope1 10%/kink 80%; bonus 2%; ltv 0.5; protocol take = 0 (none exists)\n")

    print("== 1. Rates across stablecoin utilization u ==")
    print("  u    | liqRate(u) | lender yield/cUSD (x1) | (x2 mult) | underwriter rate (flat, owner-set, floor 0) | protocol")
    for u in UTILS:
        r = liquidity_rate_default(int(u * RAY)) / RAY
        print(" %.2f  |   %5.2f%%   |        %5.2f%%          |  %5.2f%%   |         %s          |   0%%" % (
            u, r * 100, r * u * 100, 2 * r * u * 100, "0% .. 100%, NOT a function of u"))
    print("  The liquidity rate rises with u (lenders are paid for scarcity); the underwriter rate does NOT move with")
    print("  anything - not utilization, not collateral vol, not health. Underwriter compensation is decoupled from risk.")

    print("\n== 2. Underwriter expected return per $1 of tranche capital, leverage L = debt/K = ltv = %.2f ==" % ltv)
    print("  gross = uwRate*L ; loss = p_def*L*(1+b) + p_vol*%.2f*(1+b)*L" % FIRST_LIQ_FRAC)
    print("  uwRate | " + " | ".join("pDef %2.0f%% pVol %2.0f%%" % (pd * 100, pv * 100) for pd in P_DEF for pv in P_VOL))
    for uw in (0.0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.10, 0.20, 0.50):
        row = []
        for pd in P_DEF:
            for pv in P_VOL:
                gross = uw * ltv
                loss = pd * ltv * (1 + b) + pv * FIRST_LIQ_FRAC * (1 + b) * ltv
                row.append("%+6.2f%%" % ((gross - loss) * 100))
        print("  %5.1f%% | " % (uw * 100) + " | ".join("%16s" % x for x in row))

    print("\n== 3. Break-even underwriter rate (below which underwriting is negative EV), by p_def x p_vol ==")
    print("  Independent of L (both sides scale with leverage) => the threshold is a pure rate:")
    for pd in P_DEF:
        row = []
        for pv in P_VOL:
            be = pd * (1 + b) + pv * FIRST_LIQ_FRAC * (1 + b)
            row.append("%5.2f%%" % (be * 100))
        print("   p_def %3.0f%%: " % (pd * 100) + "  ".join("pVol %2.0f%% -> uwRate* >= %s" % (pv * 100, x) for pv, x in zip(P_VOL, row)))
    print("  CapDeployer default 20% clears every cell; production default is whatever the market owner sets,")
    print("  and the code permits 0%, at which underwriting is negative EV at ANY nonzero default probability.")

    print("\n== 4. When the system needs underwriters most: utilization high, collateral falling ==")
    print("  At u -> 1 the lender rate doubles (10% -> 20%, or 40% at x2) while the underwriter rate stays flat.")
    print("  Underwriter net EV is invariant to u, but the tranche's REDEEMABILITY is not: lockedValue = debt/(lt-buffer)")
    print("  = debt/0.7 = 1.43x debt is locked in the tranches, so at credit-util 100% (debt = 0.5 K) 71% of K cannot")
    print("  leave. The rational underwriter therefore queues to exit whenever expected return turns negative, and")
    print("  the queue only settles as debt is repaid - i.e. exactly when repayment is least likely.")
    for x in (0.25, 0.5, 0.75, 1.0):
        debt_over_K = x * ltv
        locked = debt_over_K / ((p["lt"] - p["buffer"]) / RAY)
        print("   credit-util %3.0f%%: locked share of tranche capital = %.0f%%, free to exit = %.0f%%" % (
            x * 100, min(1, locked) * 100, max(0, 1 - locked) * 100))

    print("\n== 5. Fee-to-risk mismatch summary ==")
    for uw in (0.0, 0.02, 0.05, 0.20):
        pd_max = uw / (1 + b)  # max default prob tolerated with p_vol 0
        print("  uwRate %4.1f%%: tolerates borrower default probability up to %5.2f%%/yr (p_vol=0) before EV < 0" % (uw * 100, pd_max * 100))

    print("\n=== HEADLINE ===")
    print("Underwriting is negative-EV whenever underwriterRate < (1+bonus)*(p_default + 0.58*p_volLiq): at 2%/yr")
    print("default risk that is 2.04%; at 5% it is 5.10%. The rate is set by the MARKET OWNER (the borrowing side),")
    print("has floor 0, and does not respond to utilization, health, or vol. Protocol take: none.")


if __name__ == "__main__":
    main()
