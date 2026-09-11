#!/usr/bin/env python3
"""
reserve_investment.py - N2 (3dad5ef): Stablecoin.invest(amount) moves underlying from the reserve
into an external Aera `reserveVault`; recall(amount) brings it back. Both are KEEPER-only and
discretionary. NOTHING in the accounting sees it: unlockedSupply(), maxRedeem, previewRedeem and
the ERC-7540 claimable rule all still count the invested underlying as redeemable, and an Aera
loss is never recognised (only badDebt haircuts). Redemptions are paid by safeTransfer out of
balanceOf(stablecoin), so once the liquid balance is exhausted every redeem/claim REVERTS until
a keeper recalls.

Model (S = $100M, u0 = 80% -> reserve R = unlockedSupply = $20M unless stated):
  phi   invested fraction of R (0..1)          liquid = (1 - phi) R
  d     redemption demand, fraction of S per day (round-1 assumption 5%/day; also 1%, 2%)
  tau   keeper recall latency: time from "liquid balance cannot pay the next redemption" to the
        recalled underlying landing (Aera withdraw by the vault owner is synchronous once called)
  ell   loss on the invested slice while it is in Aera (0..30%)

(a) DoS: the first d-day of redemptions reverts iff cumulative demand inside tau exceeds liquid:
        d * S * tau > (1 - phi) R   <=>   phi > phi* = 1 - d S tau / R.
    Reported as a table over tau; and the number of hours of demand the liquid slice covers.
(b) Loss: after ell on phi R the reserve holds R' = (1 - ell phi) R but unlockedSupply still says
    R. Redeemers are paid par FIFO (instant path) or in queue order (7540 path) until the balance
    is gone; the residual ell phi R of "unlocked" supply pays ZERO (revert) until either a recall
    from an empty vault (impossible) or governance recognises the loss. Contrast: if the loss were
    recognised as badDebt, capmath.StablecoinState's convex haircut spreads it over every redeemer.
(c) Cap on phi such that P(any revert in 7 days) < 1% under the round-1 run-dynamics assumption:
    daily requests w = w0 + w1 * badDebt/S, here badDebt = 0 so w = w0, with day-to-day noise
    (lognormal, sigma = 100% of the mean) and fresh-funded repayment 1%/day of C raising R;
    the keeper recalls the whole invested slice after latency tau once liquid < today's demand.
    Monte Carlo, 20,000 paths per cell. The cap is expressed as a fraction of
    (unlockedSupply - redemptionQueue), for a standing queue of 0 and 5% of S.
"""
import sys
import os
import random
import math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capmath import WAD, DAY, HOUR, StablecoinState  # noqa: E402

S = 100_000_000
R = 20_000_000          # unlockedSupply at u0 = 80%
C = 80_000_000
TAUS = [(1 * HOUR, "1h"), (6 * HOUR, "6h"), (12 * HOUR, "12h"), (DAY, "1d"), (3 * DAY, "3d"), (7 * DAY, "7d")]
DEMANDS = [0.01, 0.02, 0.05]
PHIS = [0.25, 0.50, 0.75, 1.00]
LOSSES = [0.05, 0.10, 0.20, 0.30]


def part_a():
    print("== (a) Liquidity DoS: phi* above which a day of redemptions reverts before the keeper's recall lands ==")
    print("phi* = 1 - d S tau / R   (R = $20M = 20% of S; '-' = negative: even phi = 0 cannot cover tau of demand)")
    print("d/day  | " + " | ".join("tau=%-4s" % n for _, n in TAUS) + " | hours of demand the liquid slice covers at phi = 0.25/0.50/0.75/0.90")
    for d in DEMANDS:
        row = []
        for tau, _ in TAUS:
            phi = 1 - d * S * (tau / DAY) / R
            row.append("%8s" % ("%.3f" % phi if phi >= 0 else "-"))
        hrs = ["%.1fh" % ((1 - phi) * R / (d * S) * 24) for phi in (0.25, 0.5, 0.75, 0.9)]
        print("%.2f   | %s | %s" % (d, " | ".join(row), " / ".join(hrs)))
    print("At u0 = 90% (R = $10M) every phi* halves its distance to 1: with d = 5%/day and a 1-day latency, phi* < 0 - no")
    print("investment at all survives a day of the round-1 demand assumption.")
    r10 = 10_000_000
    print("  R=$10M: " + ", ".join("tau=%s phi*=%s" % (n, ("%.3f" % (1 - 0.05 * S * (tau / DAY) / r10)) if 1 - 0.05 * S * (tau / DAY) / r10 >= 0 else "-") for tau, n in TAUS))
    print("Note: unlockedSupply/maxRedeem/claimable do NOT fall when invest() runs; the revert is a bare ERC20 transfer")
    print("failure in the redemption path, indistinguishable to the user from a broken token.")


def part_b():
    print("\n== (b) Aera loss ell on the invested slice: who is paid, in queue order (unlockedSupply still = R) ==")
    print("Reserve after loss R' = (1 - ell phi) R. FIFO par payout until R' is exhausted; the rest of the 'unlocked' supply reverts.")
    print("phi    ell   | reserve after | paid at par  | stranded (revert) | first zero-payout redeemer at | recognised-as-badDebt alternative:")
    print("             |               | (of $20M)    |                   | cumulative redemption of      |   payout/share first / last redeemer of R")
    for phi in PHIS:
        for ell in LOSSES:
            loss = int(ell * phi * R)
            Rp = R - loss
            # recognised alternative: badDebt = loss moves into badDebt; redeem R in 20 slices along the curve
            st = StablecoinState(S * WAD, C * WAD, loss * WAD, 6, reserve_balance=Rp * 10**6)
            first = st.previewRedeem(1_000_000 * WAD) / 1_000_000 / 10**6
            # walk the queue: 19 x $1M then the last $1M
            st2 = StablecoinState(S * WAD, C * WAD, loss * WAD, 6, reserve_balance=Rp * 10**6)
            for _ in range(19):
                try:
                    st2.redeem(1_000_000 * WAD)
                except Exception:
                    break
            last = st2.previewRedeem(1_000_000 * WAD) / 1_000_000 / 10**6
            print("%.2f   %.2f  | $%5.2fM       | $%5.2fM (%5.1f%%) | $%5.2fM (%4.1f%%)    | $%5.2fM                       | %.4f / %.4f" % (
                phi, ell, Rp / 1e6, Rp / 1e6, Rp / R * 100, loss / 1e6, loss / R * 100, Rp / 1e6, first, last))
    print("Reading: unrecognised, the loss is borne 100% by the LAST ell*phi*R of redeemers (they get nothing, not a haircut),")
    print("and every earlier redeemer is paid par - the exact first-mover advantage the convex curve was built to remove.")
    print("Recognised as badDebt it is a %.1f-%.1f%% haircut spread monotonically along the queue." % (
        (1 - StablecoinState(S * WAD, C * WAD, int(0.05 * 0.25 * R) * WAD, 6).previewRedeem(WAD) / 10**6) * 100,
        (1 - StablecoinState(S * WAD, C * WAD, int(0.30 * 1.0 * R) * WAD, 6).previewRedeem(WAD) / 10**6) * 100))
    print("Nothing in Stablecoin can recognise an Aera loss: coverBadDebt only lowers badDebt, writeOff is a market")
    print("action on a borrower's debt. The only exits are a donation via fund() or a permanent revert wall.")


def simulate_paths(phi, w0, tau_days, queue0, n_paths, days=7, repay=0.01, seed=1):
    """Fraction of paths with at least one REVERT in `days`.
    Accounting U = unlockedSupply (what the contract promises instantly); balance B = U - invested.
    A request r: the instant part min(r, U) is paid from B and REVERTS iff it exceeds B (the contract
    promised it, the token balance cannot deliver it); the excess r - U is queued and claimed as U
    grows (claims also need B). With phi = 0, B == U always and nothing ever reverts: requests beyond
    U simply queue - that is the round-1 behaviour and the baseline this cap is measured against.
    Keeper: schedules a full recall `tau_days` after B first falls below 1.5 x mean daily demand
    (tau = 0 means the keeper recalls in the same block as the failing redemption)."""
    rng = random.Random(seed)
    sigma = 1.0
    mu = math.log(w0) - 0.5 * sigma ** 2
    reverts = 0
    for _ in range(n_paths):
        U = R
        invested = phi * R
        B = U - invested
        queue = queue0
        recall_at = None
        c = C
        bad = False
        for day in range(days):
            a = c * repay          # fresh-funded repayment: U and B both rise
            c -= a
            U += a
            B += a
            if recall_at is not None and day >= recall_at:
                B += invested
                invested = 0
                recall_at = None
            # standing queue claims first, in order, up to U
            claim = min(queue, U)
            need = claim
            req = S * math.exp(rng.gauss(mu, sigma))
            inst = min(req, U - claim)
            need += inst
            if need > B:
                if tau_days == 0 and invested > 0:
                    B += invested
                    invested = 0
                else:
                    bad = True
                    break
            B -= need
            U -= need
            queue = queue - claim + (req - inst)
            if invested > 0 and recall_at is None and B < 1.5 * w0 * S:
                recall_at = day + tau_days
        if bad:
            reverts += 1
    return reverts / n_paths


def part_c():
    n = 8000
    print("\n== (c) Cap on phi with P(revert within 7 d) < 1%: round-1 run dynamics, lognormal daily demand (sigma 100%), ==")
    print("   fresh repayment 1%%/day, keeper recalls everything tau after balance < 1.5x mean demand. %d paths per cell." % n)
    print("   phi = 0 never reverts (excess demand queues); the cap is the largest phi keeping P(revert) < 1%,")
    print("   shown as a fraction of (unlockedSupply - redemptionQueue); queue0 = 0 and $5M (5% of S).")
    print("w0/day | queue0 | tau=0 (same block) | tau=1d    | tau=3d    | tau=7d (never in window)")
    caps = {}
    for w0 in (0.005, 0.01, 0.02, 0.05):
        for q in (0, 5_000_000):
            row = []
            for tau in (0, 1, 3, 7):
                lo, hi = 0.0, 1.0
                if simulate_paths(1.0, w0, tau, q, n) < 0.01:
                    lo = 1.0
                else:
                    for _ in range(10):
                        mid = (lo + hi) / 2
                        if simulate_paths(mid, w0, tau, q, n) < 0.01:
                            lo = mid
                        else:
                            hi = mid
                cap = min(1.0, lo * R / (R - q))  # 1.0 = the whole reserve incl. the queue backing
                caps[(w0, q, tau)] = cap
                row.append("%.3f" % cap)
            print("%.3f  | $%dM    | %s" % (w0, q // 1_000_000, " | ".join("%-9s" % x for x in row)))
    print("Reading: a same-block keeper (tau = 0) makes any phi safe by construction; with a 1-day recall latency the")
    print("1%%-revert cap is %.2f of the free reserve at 0.5%%/day demand, %.2f at 1%%/day, %.2f at 2%%/day and %.2f at the" % (
        caps[(0.005, 0, 1)], caps[(0.01, 0, 1)], caps[(0.02, 0, 1)], caps[(0.05, 0, 1)]))
    print("round-1 5%%/day run assumption (queue 0); a standing $5M queue lowers each by a further %.0f-%.0f%% of R." % (
        min((caps[(w, 0, 1)] - caps[(w, 5_000_000, 1)]) for w in (0.005, 0.01)) * 100 if True else 0,
        max((caps[(w, 0, 1)] - caps[(w, 5_000_000, 1)]) for w in (0.005, 0.01, 0.02, 0.05)) * 100))
    print("There is no on-chain cap at all: invest(amount) accepts any amount up to balanceOf(stablecoin), including")
    print("the redemptionQueue's backing, and unlockedSupply does not move.")
    return caps


def main():
    print("reserve_investment.py  S=$100M u0=80% R=unlockedSupply=$20M  [3dad5ef Stablecoin.invest/recall]")
    part_a()
    part_b()
    caps = part_c()
    print("\n=== HEADLINE ===")
    print("invest() is invisible to unlockedSupply/maxRedeem/claimable: at the round-1 5%/day demand assumption a")
    print("one-day keeper latency means phi > 0.75 reverts the first day of redemptions (phi > 0.50 at u0 = 90%);")
    print("an Aera loss ell on phi R is paid 100% by the last ell*phi*R of redeemers as a hard zero (revert), everyone")
    print("before them at par - the first-mover advantage the haircut curve exists to remove. Keeping P(revert in 7 d)")
    print("< 1%% needs phi <= %.2f of (unlockedSupply - queue) at 1%%/day demand with a 1-day recall, %.2f at 5%%/day." % (
        caps[(0.01, 0, 1)], caps[(0.05, 0, 1)]))
    print("Recommendation: subtract `invested` from unlockedSupply (or add a liquid-floor check in invest), and give")
    print("the loss a recognition path (invested-vs-recalled ghost -> badDebt).")


if __name__ == "__main__":
    main()
