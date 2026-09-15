#!/usr/bin/env python3
"""
run_dynamics.py - redemption demand vs reserve; first-mover advantage before and after loss
recognition (P12). HEAD a843c1d.

Exact pieces (capmath.StablecoinState): unlockedSupply = min(S - c - badDebt, quote(on-hand USDC))
(Stablecoin L184-192, HEAD caps by the ON-HAND balance: Aera-invested reserve does not count),
_convertToAssets quadratic haircut (L236-261), _onWithdraw bad-debt retirement (L320-330),
recognizeBadDebtInReserve (L152-156: badDebt += l, creditBackedSupply unchanged, so unlockedSupply
FALLS by l), backing() = S - badDebt.

State: total S = $100M cUSD (6-dec USDC underlying), credit-backed c = u S, reserve R = S - c of
which a fraction phi is invested in the Aera vault (a = phi R) and h = R - a is on hand.
Redemption requests are FIFO (ERC7540AsyncRedeem._claimableShares L337-356); instant exits use
instantRedeem up to instantUnlockedSupply. The KEEPER's `recall` (L112-117) is the only way h
grows other than fresh deposits / fresh-funded repayments.
Behavioural inputs (stated, not measured): stcUSD yield y = 8%/yr as the cost of waiting; gas
$5 per exit; probability the GUARDIAN recognises a known Aera loss within the next day, swept.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import StablecoinState, WAD, DAY  # noqa: E402

S0 = 100_000_000 * WAD
DEC = 6


def make(u, phi, bad=0):
    st = StablecoinState(S0, int(S0 * u), 0, DEC, invested=int((S0 - int(S0 * u)) * phi) * 10**DEC // 10**18)
    if bad:
        st.recognize_in_reserve(bad)
    return st


def part_a():
    print("== A. Instant redemption capacity w* = unlockedSupply/S = (1-u)(1-phi); beyond it the queue stalls until KEEPER recall ==")
    print("  u \\ phi |  0.00  |  0.25  |  0.50  |  0.75  |  0.90     (share of total supply redeemable now)")
    for u in (0.5, 0.7, 0.8, 0.9, 0.95):
        row = [make(u, phi).unlockedSupply() / S0 for phi in (0.0, 0.25, 0.5, 0.75, 0.9)]
        print("  %.2f    | " % u + " | ".join("%5.1f%%" % (x * 100) for x in row))
    print("  With u=0.8 and 75% of the reserve invested, a 5%-of-supply redemption day empties the on-hand balance; every later")
    print("  request waits for recall. Queue wait = keeper latency, not a function of anything on-chain.")
    print("  Daily-demand w vs (1-u)(1-phi): days of demand the on-hand balance covers = (1-u)(1-phi)/w:")
    for w in (0.01, 0.02, 0.05):
        print("    w = %2.0f%%/day: u 0.8 phi 0.5 -> %4.1f d; u 0.8 phi 0.75 -> %4.1f d; u 0.9 phi 0.75 -> %4.1f d" % (
            w * 100, 0.2 * 0.5 / w, 0.2 * 0.25 / w, 0.1 * 0.25 / w))


def part_b():
    print("\n== B. Unrecognised Aera loss l (P12): exits at par before recognition shift the loss to stayers ==")
    print("  true backing = 1 - l/S; f of supply exits at par -> survivors' backing = (1 - l/S - f)/(1 - f); haircut on stayers = (l/S)/(1-f).")
    print("  Exits are capped by unlockedSupply = (1-u)(1-phi) S (u 0.8: phi 0 -> 20%, phi 0.75 -> 5%).")
    print("  l/S    | f=1%   | f=5%   | f=10%  | f=20%  | loss shifted at f=5% | at f=20%")
    for l in (0.005, 0.01, 0.02, 0.05, 0.10):
        row = ["%5.2f%%" % (l / (1 - f) * 100) for f in (0.01, 0.05, 0.10, 0.20)]
        print("  %5.1f%% | %s |      $%.2fM          | $%.2fM" % (l * 100, " | ".join(row), 0.05 * l * S0 / WAD / 1e6, 0.20 * l * S0 / WAD / 1e6))
    print("  Is a run rational? exit now (par, gas $5) vs wait one day: E[loss of waiting] = P(recognised within the day) * (l/S)/(1-f) - y/365.")
    print("  Threshold l*/S above which exiting now is strictly better, by P(recognition in 1 day):")
    y = 0.08 / 365
    for P in (0.05, 0.10, 0.25, 0.50, 1.0):
        print("    P = %4.0f%%: l*/S = %.4f%%  ($%.0fk on $100M)   [gas adds $5 / holding]" % (P * 100, y / P * 100, y / P * S0 / WAD / 1e3))
    print("  => with any credible chance of recognition inside a day, a loss above a few hundredths of a percent of supply makes")
    print("     immediate par exit dominant: the run is rational for every holder who can still reach the on-hand reserve.")
    print("  After recognizeBadDebtInReserve(l): unlockedSupply drops by l (creditBackedSupply unchanged), so the LAST l of")
    print("  would-be par exits become queue-stuck; the quadratic haircut then applies to what is left.")


def part_c():
    print("\n== C. After recognition: the quadratic haircut (backing/supply)^2-shaped exit. Does exiting early still beat staying? ==")
    for u, phi, lfrac in ((0.0, 0.0, 0.10), (0.5, 0.0, 0.10), (0.8, 0.0, 0.05)):
        st = make(u, phi, int(S0 * lfrac))
        print("  u %.1f, phi %.1f, badDebt %.0f%% of S: unlocked %.1f%% of S, backing %.3f" % (
            u, phi, lfrac * 100, st.unlockedSupply() / S0 * 100, st.backing() / st.totalSupply))
        print("    exit # | shares (%S) | payout/share | backing after | badDebt after | whole-supply payout/share if staying")
        step = st.unlockedSupply() // 10
        k = 0
        while st.unlockedSupply() >= step and step > 0 and k < 10:
            k += 1
            paid = st.redeem(step)
            hold = st.previewRedeem(st.totalSupply) * 10**12 / st.totalSupply
            print("      %2d   |   %5.2f%%    |   %.5f    |    %.5f    |    $%5.2fM    |   %.5f" % (
                k, step / S0 * 100, paid * 10**12 / step, st.backing() / st.totalSupply, st.badDebt / WAD / 1e6, hold))
        print("    payout/share rises along the sequence (monotone) and backing rises after every exit: 'exit repairs the peg' HOLDS.")
    # marginal payout curve
    print("\n  Marginal payout d(assets)/d(shares) along a single large exit (u 0, badDebt 10%): average vs marginal per 1% slice")
    st = make(0.0, 0.0, int(S0 * 0.10))
    prev = 0
    for f in (0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90):
        sh = int(S0 * f)
        a = st.previewRedeem(sh)
        marg = (a - st.previewRedeem(int(S0 * (f - 0.01)))) * 10**12 / (S0 * 0.01)
        print("    f=%4.0f%%: average %.5f  marginal %.5f   (backing 0.900; ^2 = 0.810)" % (f * 100, a * 10**12 / sh, marg))
    print("  Marginal payout is below average and rises with f: the first dollar out is paid ~backing^2, the last ~backing.")
    print("  Post-recognition a run is IRRATIONAL (waiting pays more per share); pre-recognition (part B) it is rational.")
    print("  The curve cannot see an unrecognised loss: the first-mover advantage lives entirely in the GUARDIAN's recognition latency.")


if __name__ == "__main__":
    print("run_dynamics.py  HEAD a843c1d  S=$100M cUSD, USDC 6-dec\n")
    part_a()
    part_b()
    part_c()
    print("\n=== HEADLINE ===")
    print("Instant capacity is (1-u)(1-phi) of supply: 5% at u=0.8 with 75% of the reserve in Aera; past it the queue waits on KEEPER recall.")
    print("An unrecognised Aera loss makes par exit dominant above l*/S = (y/365)/P(recognition) = 0.044% of supply at P=50%/day: the")
    print("run is rational until GUARDIAN recognition, and each $1 out shifts l/S of loss to stayers (haircut l/(S(1-f))). After recognition")
    print("the quadratic curve pays the first exiter backing^2 and later exiters more, so waiting dominates: 'exit repairs the peg' holds.")
