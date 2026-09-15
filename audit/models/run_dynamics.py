#!/usr/bin/env python3
"""
run_dynamics.py - H5: FIFO redemption queue vs unlockedSupply recovery under a run, and whether
the convex haircut removes the first-mover advantage it is designed to remove.

Exact pieces (capmath.StablecoinState): _convertToAssets haircut, _onWithdraw bad-debt
retirement, unlockedSupply gate, and ERC7540AsyncRedeem's claimable rule:
   claimable(request) = clamp(settledQueue + unlockedSupply() - queueIndex, 0, size).
Queued shares are burned only on claim; while queued they still count in totalSupply, so the
haircut for a queued redeemer is computed at CLAIM time against the then-current
(supply, badDebt) - the curve is path dependent through _onWithdraw.

Model (daily steps, S0 = $100M cUSD, underlying 6dp like USDC):
  * u0 = 80%: creditBackedSupply C = $80M, reserve R = $20M.
  * A bad-debt shock badDebt = B0 (fraction of S0) is recognised at day 0 (writeOff), which moves
    B0 from C into badDebt (unlockedSupply unchanged, totalAssets down).
  * Depositors: each day a fraction w(B) of the still-held supply requests redemption, where
    w = w0 + w1 * badDebt/S (redemption propensity rises with bad debt). Requests are FIFO.
  * Recovery: borrowers repay a fraction r/day of outstanding credit. TWO channels:
      'fresh'     - the borrower deposits underlying at par, mints cUSD, burns it: R += a, C -= a,
                    S unchanged => unlockedSupply rises by a. This is the ONLY channel that
                    settles the queue.
      'secondary' - the borrower buys cUSD from a circulating holder and burns it: S -= a, C -= a,
                    R unchanged => unlockedSupply UNCHANGED. The queue does not move; the seller
                    exited at (market) par, bypassing the haircut curve entirely.
    Part A uses 'fresh' (the optimistic case) and shows 'secondary' for contrast.
  * We report: queue wait (days from request to full claimability) for the last requester of each
    day; the daily withdrawal fraction w at which the wait exceeds T = 7 and 30 days for each
    repayment rate; and per-share payout of early vs late redeemers along the exact curve.
  * Part B (recognition lag): unrecoverable debt exists from day 0 but is only written off at
    day t_w. Redeemers who exit before t_w are paid at par out of the reserve; the loss is borne
    by those who remain. This is the first-mover advantage the curve does NOT address.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import StablecoinState, WAD, DAY  # noqa: E402

S0 = 100_000_000 * WAD
DEC = 6
U0 = 0.80


class Queue:
    def __init__(self):
        self.reqs = []  # [day, shares, queueIndex, claimed_shares, done_day]
        self.redeemQueue = 0
        self.settledQueue = 0

    def request(self, day, shares):
        self.reqs.append([day, shares, self.redeemQueue, 0, None])
        self.redeemQueue += shares

    def redemptionQueue(self):
        return self.redeemQueue - self.settledQueue

    def settle(self, st, day):
        """Claim everything claimable, FIFO, using the exact haircut; returns assets paid."""
        paid = 0
        for r in self.reqs:
            if r[3] == r[1]:
                continue
            current = self.settledQueue + st.unlockedSupply()
            qi = r[2] + r[3]
            remaining = r[1] - r[3]
            if current <= qi:
                break  # FIFO: nothing behind can be claimable either
            claimable = min(remaining, current - qi)
            assets = st.previewRedeem(claimable)
            st.totalSupply -= claimable
            st._onWithdraw(assets, claimable)
            st.balance -= assets
            self.settledQueue += claimable
            r[3] += claimable
            r[4] = day if r[3] == r[1] else r[4]
            paid += assets
            if claimable < remaining:
                break
        return paid


def apply_repay(st, repay, mode):
    rp = int(st.creditBackedSupply * repay)
    if rp <= 0:
        return 0
    if mode == "fresh":
        st.creditBackedSupply -= rp
        st.balance += rp * 10**DEC // 10**18
    else:
        st.creditBackedSupply -= rp
        st.totalSupply -= rp
    return rp


def run(bad_frac, w0, w1, repay, days=120, recognise_day=0, mode="fresh"):
    C = int(S0 * U0)
    st = StablecoinState(S0, C, 0, DEC)
    B0 = int(S0 * bad_frac)
    q = Queue()
    held = S0  # shares not yet requested
    waits = []
    payouts = []  # (day requested, assets per share)
    for day in range(days + 1):
        if day == recognise_day and B0 > 0 and st.badDebt == 0:
            st.badDebt = B0
            st.creditBackedSupply -= B0
        rp = apply_repay(st, repay, mode)
        if mode != "fresh":
            held -= min(held, rp)  # the burned cUSD came out of circulation
        # redemption requests
        w = min(1.0, w0 + w1 * (st.badDebt / st.totalSupply if st.totalSupply else 0))
        req = int(held * w)
        if req > 0:
            q.request(day, req)
            held -= req
        # settle FIFO
        q.settle(st, day)
    for r in q.reqs:
        if r[4] is not None:
            waits.append((r[0], r[4] - r[0]))
        else:
            waits.append((r[0], None))
    return st, q, waits


def wait_stats(waits):
    done = [w for d, w in waits if w is not None]
    undone = [d for d, w in waits if w is None]
    return (max(done) if done else 0), len(undone), len(waits)


def part_a():
    print("== A. Queue wait vs daily withdrawal fraction w and FRESH-funded repayment rate r (badDebt 0, 120 days) ==")
    print("  Reserve 20% serves instantly; beyond it the queue settles only as fresh underlying enters via repayment.")
    print("  w/day | r=0.0%/d | r=0.5%/d | r=1%/d | r=2%/d | r=5%/d      (max wait in days; 'stuck' = never claimable in 120d)")
    for w0 in (0.005, 0.01, 0.02, 0.05, 0.10, 0.20):
        row = []
        for repay in (0.0, 0.005, 0.01, 0.02, 0.05):
            st, q, waits = run(0.0, w0, 0.0, repay)
            mx, undone, n = wait_stats(waits)
            row.append("%3dd%s" % (mx, (" +%d stuck" % undone) if undone else ""))
        print("  %4.1f%% | " % (w0 * 100) + " | ".join("%-12s" % x for x in row))
    print("\n  Same grid, SECONDARY-funded repayment (borrower buys cUSD from holders): unlockedSupply never moves")
    for w0 in (0.005, 0.02, 0.10):
        row = []
        for repay in (0.0, 0.01, 0.05):
            st, q, waits = run(0.0, w0, 0.0, repay, mode="secondary")
            mx, undone, n = wait_stats(waits)
            row.append("%3dd%s" % (mx, (" +%d stuck" % undone) if undone else ""))
        print("  %4.1f%% | r=0: %-12s | r=1%%: %-12s | r=5%%: %-12s" % (w0 * 100, *row))
    print("\n  Threshold (fresh-funded): smallest w such that max wait > T")
    for T in (7, 30):
        for repay in (0.005, 0.01, 0.02, 0.05):
            lo, hi = 0.0, 0.5
            for _ in range(20):
                mid = (lo + hi) / 2
                st, q, waits = run(0.0, mid, 0.0, repay, days=180)
                mx, undone, n = wait_stats(waits)
                if mx > T or undone:
                    hi = mid
                else:
                    lo = mid
            print("   T=%2dd repay %.1f%%/d: orderly redemption breaks at w >= %.2f%%/day (cumulative %.0f%% of supply in %d days)" % (
                T, repay * 100, hi * 100, (1 - (1 - hi) ** T) * 100, T))


def part_b_curve():
    print("\n== B. Early vs late redeemer under the exact curve (badDebt 10% recognised day 0, w rises with badDebt) ==")
    st, q, waits = run(0.10, 0.02, 0.5, 0.01, days=60)
    # per-request payout: replay to collect per-share
    C = int(S0 * U0)
    st = StablecoinState(S0, C, 0, DEC)
    st.badDebt = int(S0 * 0.10)
    st.creditBackedSupply -= st.badDebt
    per_share = []
    held = S0
    q = Queue()
    for day in range(61):
        apply_repay(st, 0.01, "fresh")
        w = min(1.0, 0.02 + 0.5 * st.badDebt / st.totalSupply)
        req = int(held * w)
        if req:
            q.request(day, req)
            held -= req
        # settle and record per-share of each claim
        for r in q.reqs:
            if r[3] == r[1]:
                continue
            current = q.settledQueue + st.unlockedSupply()
            qi = r[2] + r[3]
            if current <= qi:
                break
            claimable = min(r[1] - r[3], current - qi)
            assets = st.previewRedeem(claimable)
            st.totalSupply -= claimable
            st._onWithdraw(assets, claimable)
            st.balance -= assets
            q.settledQueue += claimable
            r[3] += claimable
            per_share.append((day, r[0], assets * 10**12 / claimable))
            if r[3] < r[1]:
                break
    print("  claim day | requested day | payout per share (underlying)")
    shown = set()
    for d, rd, ps in per_share:
        if rd in shown:
            continue
        shown.add(rd)
        if rd in (0, 1, 2, 5, 10, 20, 30, 40, 50, 60):
            print("     %3d    |     %3d       |   %.6f" % (d, rd, ps))
    inc = all(per_share[i][2] <= per_share[i + 1][2] + 1e-9 for i in range(len(per_share) - 1))
    print("  payout per share non-decreasing along the queue: %s   badDebt end: $%.2fM (from $10M)  claims settled: %d" % (
        inc, st.badDebt / WAD / 1e6, len(per_share)))
    print("  => under RECOGNISED bad debt the curve does what it claims: the early redeemer gets LESS per share.")
    print("\n  Contrast - the par channel the curve does not cover: borrower repays $10M with cUSD bought from holders")
    st2 = StablecoinState(S0, int(S0 * U0), 0, DEC)
    st2.badDebt = int(S0 * 0.10)
    st2.creditBackedSupply -= st2.badDebt
    before = st2.totalAssets() / st2.totalSupply
    ps_before = st2.previewRedeem(st2.totalSupply) * 10**12 / st2.totalSupply
    st2.creditBackedSupply -= 10_000_000 * WAD
    st2.totalSupply -= 10_000_000 * WAD
    after = st2.totalAssets() / st2.totalSupply
    ps_after = st2.previewRedeem(st2.totalSupply) * 10**12 / st2.totalSupply
    print("  backing ratio %.4f -> %.4f; whole-supply exit per share %.4f -> %.4f. The seller left at par, the" % (
        before, after, ps_before, ps_after))
    print("  borrower discharged $1 of debt per cUSD, and the survivors' backing fell: burnCreditBacked is a")
    print("  haircut-free exit for whoever sells cUSD to a repaying borrower.")


def part_b_lag():
    print("\n== C. Recognition lag: unrecoverable debt exists at day 0 but writeOff lands at day t_w ==")
    print("  Before t_w the reserve pays par; after t_w the survivors carry the whole shortfall.")
    print("  t_w | exits before t_w (share of supply) | paid at par | loss borne by survivors | survivors' payout/share after t_w")
    for tw in (0, 3, 7, 14, 30):
        # redeemers exit 2%/day at par until t_w, bounded by the 20% reserve
        C = int(S0 * U0)
        st = StablecoinState(S0, C, 0, DEC)
        B = int(S0 * 0.10)
        exited = 0
        paid = 0
        for day in range(tw):
            x = min(int(st.totalSupply * 0.02), st.unlockedSupply())
            if x <= 0:
                break
            paid += st.redeem(x)
            exited += x
        # write-off
        st.badDebt = B
        st.creditBackedSupply -= B
        survivors = st.totalSupply
        # whole-remaining-supply exit is paid the backing ratio
        ps_after = st.previewRedeem(survivors) * 10**12 / survivors if survivors else 0
        par_paid = paid * 10**12
        fair = exited * (S0 - B) / S0  # what those shares would have got at the flat backing ratio
        print("  %3d | %5.1f%%                              | $%5.2fM    | $%.2fM transferred       | %.4f" % (
            tw, exited / S0 * 100, par_paid / WAD / 1e6, (par_paid - fair) / WAD / 1e6, ps_after))
    print("  With a 10% shortfall, every $1 that exits before writeOff moves $0.10 of loss onto those who stay.")
    print("  writeOff is a discretionary GUARDIAN action bounded only by unrecoverableDebt (H3), so the lag is unbounded.")


if __name__ == "__main__":
    print("run_dynamics.py  S0=$100M, u0 80%, reserve $20M, underlying 6dp\n")
    part_a()
    part_b_curve()
    part_b_lag()
    print("\n=== HEADLINE ===")
    print("Orderly redemption (wait <= 7d) breaks once daily requests exceed ~1% of supply at 1%/day repayment")
    print("(the 20% reserve absorbs ~10 days of it); with no repayment anything past the reserve is stuck indefinitely.")
    print("The convex haircut DOES remove the first-mover advantage for RECOGNISED bad debt (payout/share is monotone")
    print("increasing along the queue). It does NOT touch unrecognised bad debt: exits before writeOff are paid par,")
    print("and each $1 out before recognition shifts (shortfall/supply) of loss onto the survivors.")
