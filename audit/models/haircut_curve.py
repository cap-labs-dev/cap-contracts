#!/usr/bin/env python3
"""
haircut_curve.py - H6 / I10 / I11: exact integer test of Stablecoin's bad-debt haircut curve.

What is replicated (bit-exact, Python ints):
  Stablecoin._convertToAssets / _convertToShares / _opposite   (contracts/cap/Stablecoin.sol L193-285)
  Stablecoin._onWithdraw retirement of (shares - assetsInShareUnits) into badDebt
  Stablecoin.unlockedSupply / totalAssets
  OZ Math.mulDiv floor / ceil, previewRedeem = convertToAssets(Floor), previewWithdraw = convertToShares(Ceil)

Assumptions:
  * State is (totalSupply, creditBackedSupply, badDebt, underlyingDecimals). The reserve balance is
    (totalSupply - creditBackedSupply - badDebt) scaled to the underlying's decimals, i.e. I1 holds
    at t=0 and we test whether the curve preserves it.
  * The redeemer only ever burns shares from unlockedSupply (the contract enforces this).
  * "Redeemer paid more than the formula intends" = a split of one redemption into n calls paying
    MORE total than the single call, or withdraw(a) burning fewer shares than redeem needs for a,
    beyond the 1-wei ERC-4626 slack.

Tests:
  T1 split-equivalence: redeem S in 1 call vs n calls (n up to 1000), equal and random splits.
  T2 round-trip deposit -> redeem <= deposit (I11), no bad debt and with bad debt.
  T3 monotonicity of previewRedeem in shares.
  T4 _onWithdraw consistency: after every redeem, unlockedSupply (18dp) <= real balance (scaled)
     and badDebt never underflows, on every decimal setting.
  T5 withdraw/redeem inverse consistency: previewRedeem(previewWithdraw(a)) >= a - slack, and
     previewWithdraw(previewRedeem(s)) <= s.
Prints the max wei deviation and its SIGN for each test, and the exact inputs of any violation.
"""
import random
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import StablecoinState, WAD, Revert, mulDiv, FLOOR, CEIL  # noqa: E402

random.seed(20260909)

SUPPLIES = [int(1e6) * WAD, int(50e6) * WAD, int(500e6) * WAD]
# shortfall as fraction of supply, in basis points of 0.01% -> 0 .. 99.99%
SHORTFALLS_BPS = [0, 1, 10, 100, 500, 1000, 2500, 5000, 7500, 9000, 9900, 9990, 9999]
DECIMALS = [6, 8, 18]
NS = [2, 3, 7, 10, 100, 1000]


def make_state(supply, shortfall_bps, dec, credit_frac=0.5):
    badDebt = supply * shortfall_bps // 10000
    # credit must leave some unlocked supply; keep credit at credit_frac of what is not bad debt
    credit = (supply - badDebt) * int(credit_frac * 1000) // 1000
    st = StablecoinState(supply, credit, badDebt, dec)
    return st


def split_redeem(st, total_shares, n, random_split):
    st = st.copy()
    if random_split:
        cuts = sorted(set(random.randrange(1, total_shares) for _ in range(n - 1))) if total_shares > n else []
        parts, prev = [], 0
        for c in cuts:
            parts.append(c - prev)
            prev = c
        parts.append(total_shares - prev)
    else:
        q, r = divmod(total_shares, n)
        parts = [q + (1 if i < r else 0) for i in range(n)]
    paid = 0
    for p in parts:
        if p == 0:
            continue
        paid += st.redeem(p)
    return paid, st


def t1_split_equivalence():
    print("== T1 split-equivalence: n calls vs 1 call (positive deviation = split pays MORE) ==")
    worst = (0, None)  # (deviation, inputs)
    best_neg = (0, None)
    cases = 0
    for supply in SUPPLIES:
        for bps in SHORTFALLS_BPS:
            for dec in DECIMALS:
                st = make_state(supply, bps, dec)
                unlocked = st.unlockedSupply()
                if unlocked == 0:
                    continue
                for num, den in ((1, 1000), (1, 10), (1, 2), (999, 1000), (1, 1)):
                    S = unlocked * num // den
                    if S < 2:
                        continue
                    one, _ = split_redeem(st, S, 1, False)
                    for n in NS:
                        if n > S:
                            continue
                        for rnd in (False, True):
                            many, _ = split_redeem(st, S, n, rnd)
                            dev = many - one
                            cases += 1
                            if dev > worst[0]:
                                worst = (dev, (supply, bps, dec, S, n, rnd))
                            if dev < best_neg[0]:
                                best_neg = (dev, (supply, bps, dec, S, n, rnd))
    print("  cases: %d" % cases)
    print("  max POSITIVE deviation (split pays more): %d wei  inputs=%s" % (worst[0], worst[1]))
    print("  max NEGATIVE deviation (split pays less): %d wei  inputs=%s" % (best_neg[0], best_neg[1]))
    return worst


def t1b_adversarial_dust():
    """Many 1-share redemptions from a low-decimal underlying: each call rounds; can dust accrue?"""
    print("== T1b adversarial: 1000 redemptions of tiny size, decimals 6, deep shortfall ==")
    worst = 0
    worst_in = None
    for bps in (5000, 9000, 9999):
        for dec in (6, 8, 18):
            supply = int(50e6) * WAD
            st = make_state(supply, bps, dec)
            for unit in (1, 10**6, 10**12, 10**12 + 1, 10**13 + 7):
                S = unit * 1000
                if S > st.unlockedSupply():
                    continue
                one, _ = split_redeem(st, S, 1, False)
                many, _ = split_redeem(st, S, 1000, False)
                dev = many - one
                if dev > worst:
                    worst, worst_in = dev, (bps, dec, unit)
    print("  max positive deviation: %d wei  inputs=%s" % (worst, worst_in))
    return worst


def t2_round_trip():
    print("== T2 round-trip deposit -> redeem (I11): payout - deposit, positive = vault loses ==")
    worst = (0, None)
    for supply in SUPPLIES:
        for bps in SHORTFALLS_BPS:
            for dec in DECIMALS:
                st = make_state(supply, bps, dec)
                for amt in (1, 7, 10**dec - 1, 10**dec, 12345 * 10**dec, 10**6 * 10**dec):
                    s2 = st.copy()
                    shares = s2.deposit(amt)
                    if shares == 0:
                        continue
                    if shares > s2.unlockedSupply():
                        continue
                    out = s2.redeem(shares)
                    dev = out - amt
                    if dev > worst[0]:
                        worst = (dev, (supply, bps, dec, amt))
    print("  max (payout - deposit): %d wei  inputs=%s" % (worst[0], worst[1]))
    # also: deposit-then-redeem-in-halves
    return worst


def t3_monotonic():
    print("== T3 previewRedeem monotonic in shares ==")
    viol = None
    for supply in SUPPLIES:
        for bps in SHORTFALLS_BPS:
            for dec in DECIMALS:
                st = make_state(supply, bps, dec)
                prev = 0
                pts = sorted(set([1, 2, 3, 10**12, 10**12 + 1, 10**18, supply // 3, supply // 2, supply - 1, supply]
                                 + [random.randrange(1, supply) for _ in range(50)]))
                for s in pts:
                    v = st.previewRedeem(s)
                    if v < prev:
                        viol = (supply, bps, dec, s, v, prev)
                        break
                    prev = v
    print("  violation: %s" % (viol,))
    return viol


def t4_onwithdraw_consistency():
    print("== T4 _onWithdraw keeps unlockedSupply <= real balance (I1) and badDebt consistent ==")
    worst_gap = None   # unlocked(18dp) - balance(18dp) : positive means I1 broken
    max_dust = 0       # balance - unlocked: vault keeps dust (safe)
    clamp_hits = 0
    for supply in SUPPLIES:
        for bps in SHORTFALLS_BPS:
            for dec in DECIMALS:
                st = make_state(supply, bps, dec)
                for _ in range(40):
                    u = st.unlockedSupply()
                    if u == 0:
                        break
                    x = random.choice([1, 10**12 + 3, u // 7 + 1, u // 2, u])
                    x = min(x, u)
                    before_bad = st.badDebt
                    assets = st.previewRedeem(x)
                    st.totalSupply -= x
                    reduced = st._onWithdraw(assets, x)
                    st.balance -= assets
                    if reduced == before_bad and before_bad > 0 and x - mulDiv(assets, 10**18, 10**dec) > before_bad:
                        clamp_hits += 1
                    bal18 = st.balance * 10**18 // 10**dec
                    gap = st.unlockedSupply() - bal18
                    if worst_gap is None or gap > worst_gap[0]:
                        worst_gap = (gap, (supply, bps, dec, x))
                    if -gap > max_dust:
                        max_dust = -gap
    print("  max (unlockedSupply - balance) in 18dp wei: %d  inputs=%s  (>0 would break I1)" % worst_gap)
    print("  max dust retained by vault (balance - unlocked): %d wei-18dp" % max_dust)
    print("  badDebt clamp (reduced > badDebt) hit: %d times" % clamp_hits)
    return worst_gap


def t5_withdraw_vs_redeem():
    print("== T5 withdraw/redeem inverse consistency ==")
    worst_a = (0, None)  # a - previewRedeem(previewWithdraw(a)) : >1 means withdraw burns too few shares
    worst_s = (0, None)  # previewWithdraw(previewRedeem(s)) - s : >0 means... vault favour check
    for supply in SUPPLIES:
        for bps in SHORTFALLS_BPS:
            for dec in DECIMALS:
                st = make_state(supply, bps, dec)
                for _ in range(60):
                    a = random.choice([1, 10**dec, random.randrange(1, max(2, st.previewRedeem(st.unlockedSupply()) or 2))])
                    sh = st.previewWithdraw(a)
                    if sh > st.unlockedSupply():
                        continue
                    back = st.previewRedeem(sh)
                    d = a - back
                    if d > worst_a[0]:
                        worst_a = (d, (supply, bps, dec, a, sh, back))
                    s = random.randrange(1, st.unlockedSupply() + 1)
                    a2 = st.previewRedeem(s)
                    sh2 = st.previewWithdraw(a2)
                    d2 = sh2 - s
                    if d2 > worst_s[0]:
                        worst_s = (d2, (supply, bps, dec, s, a2, sh2))
    print("  max a - previewRedeem(previewWithdraw(a)) [assets wei]: %d  inputs=%s" % worst_a)
    print("     (withdraw pays `a` for previewWithdraw(a) shares; a value > 1 asset-wei means the withdrawer")
    print("      is paid more than those shares are worth under redeem -> compare to 1 unit of underlying)")
    print("  max previewWithdraw(previewRedeem(s)) - s [shares]: %d  inputs=%s" % worst_s)
    return worst_a, worst_s


def t6_deposit_to_improve_exit():
    """NatSpec claim: 'Depositing to improve an exit does not work: minting at par lowers k, but by
    less than the par mint costs.' Attacker holds x shares; compares redeem(x) against
    deposit(D) then redeem(x + shares(D)), net of D. Positive gain = claim refuted."""
    print("== T6 deposit-at-par-then-redeem vs plain redeem (positive = attacker gains) ==")
    worst = (-(10**40), None)
    for supply in SUPPLIES:
        for bps in (100, 1000, 5000, 9000, 9999):
            for dec in DECIMALS:
                st = make_state(supply, bps, dec, credit_frac=0.3)
                unlocked = st.unlockedSupply()
                for xn, xd in ((1, 100), (1, 10), (1, 2), (1, 1)):
                    x = unlocked * xn // xd
                    if x == 0:
                        continue
                    plain = st.copy().redeem(x)
                    for Dn, Dd in ((1, 100), (1, 10), (1, 1), (10, 1)):
                        D = supply * Dn // Dd * 10**dec // 10**18
                        s2 = st.copy()
                        sh = s2.deposit(D)
                        got = s2.redeem(x + sh)
                        gain = got - D - plain
                        if gain > worst[0]:
                            worst = (gain, (supply, bps, dec, x, D))
    print("  max attacker gain: %d asset-wei  inputs=%s" % worst)
    return worst


def curve_shape():
    print("== Curve shape (supply $50M, 18dp): payout per share for redeeming fraction f of supply ==")
    print("  shortfall | f=0.1%% | f=10%% | f=50%% | f=100%% | backing ratio | ratio^2 ")
    supply = int(50e6) * WAD
    for bps in (100, 1000, 5000, 9000, 9999):
        st = make_state(supply, bps, 18, credit_frac=0.0)
        backing = (supply - st.badDebt) / supply
        row = []
        for num, den in ((1, 1000), (1, 10), (1, 2), (1, 1)):
            sh = supply * num // den
            row.append(st.previewRedeem(sh) / sh)
        print("  %6.2f%%  | %.6f | %.6f | %.6f | %.6f | %.6f | %.6f" % (bps / 100, *row, backing, backing**2))


def sequential_payout_direction():
    """Does the k-th redeemer in a sequence get more or less per share than the first?"""
    print("== Sequential redeemers (10 x 5% of supply, shortfall 20%, no credit): per-share payout ==")
    supply = int(50e6) * WAD
    st = make_state(supply, 2000, 18, credit_frac=0.0)
    x = supply // 20
    prev = None
    seq = []
    for i in range(10):
        paid = st.redeem(x)
        seq.append(paid / x)
    print("  " + " ".join("%.5f" % v for v in seq))
    print("  monotone increasing: %s  (design intent: later redeemer gets MORE per share)"
          % all(seq[i] <= seq[i + 1] for i in range(len(seq) - 1)))


if __name__ == "__main__":
    curve_shape()
    sequential_payout_direction()
    w1 = t1_split_equivalence()
    w1b = t1b_adversarial_dust()
    w2 = t2_round_trip()
    w3 = t3_monotonic()
    w4 = t4_onwithdraw_consistency()
    w5 = t5_withdraw_vs_redeem()
    w6 = t6_deposit_to_improve_exit()
    print()
    print("=== HEADLINE ===")
    print("split-equivalence max over-payment: %d wei (I10 %s)" % (w1[0], "HOLDS" if w1[0] <= 1 else "BROKEN"))
    print("dust split max over-payment:        %d wei" % w1b)
    print("round-trip max over-payment:        %d wei (I11 %s)" % (w2[0], "HOLDS" if w2[0] <= 0 else "BROKEN"))
    print("monotonicity violation:             %s" % (w3 is not None))
    print("I1 (unlocked <= balance) max gap:   %d wei (%s)" % (w4[0], "HOLDS" if w4[0] <= 0 else "BROKEN"))
    print("withdraw-vs-redeem slack (assets):  %d wei" % w5[0][0])
    print("deposit-to-improve-exit max gain:   %d asset-wei (claim %s)" % (w6[0], "HOLDS" if w6[0] <= 0 else "REFUTED"))
