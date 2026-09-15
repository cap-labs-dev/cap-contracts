#!/usr/bin/env python3
"""
Cap v2 round-3 audit, Workstream A (Math).

Bit-exact Python ports of the Cap-authored WadRayMath functions
(rayMul, rayDiv, rayPow, rayPowRay, rayLn, rayExp) at commit a843c1d,
plus MathUtils.calculateCompoundedInterest and FloatingMarket._growIndex,
diffed against mpmath at high precision.

Every integer operation below mirrors the Solidity statement it is named after:
  * rayMul / rayDiv                -> half-up (add HALF then floor-divide), Aave semantics
  * Math.mulDiv(a, b, c)           -> exact floor(a*b/c) (OZ uses a 512-bit intermediate;
                                      Python big ints are exact, so `a*b//c` is bit-identical)
  * `x /= 2`, `term / n`, `/ SPY`  -> floor
  * `exp <<= k`                    -> unchecked shift; we model the wrap explicitly

Outputs go to audit/v3/models/output/wadray_check.txt (summary) and a few CSVs.
Run:  venv/bin/python audit/v3/models/wadray_check.py [--points N]
"""
import argparse
import os
import random
import sys
import time

from mpmath import mp, mpf, ln as mpln, exp as mpexp, power as mppower

mp.dps = 80

RAY = 10**27
HALF_RAY = RAY // 2
WAD = 10**18
LN2_RAY = 693147180559945309417232121
SPY = 365 * 24 * 3600
U256 = 2**256

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
os.makedirs(OUT_DIR, exist_ok=True)
LOG = None  # opened in main(); importing this module (e.g. to reuse the ports) must not truncate the log


def log(*a):
    s = " ".join(str(x) for x in a)
    print(s)
    if LOG is not None:
        LOG.write(s + "\n")
        LOG.flush()


# ---------------------------------------------------------------------------
# Bit-exact ports
# ---------------------------------------------------------------------------
class Revert(Exception):
    pass


def rayMul(a, b):
    # WadRayMath.sol:58-65
    if b != 0 and a > (U256 - 1 - HALF_RAY) // b:
        raise Revert("rayMul overflow")
    return (a * b + HALF_RAY) // RAY


def rayDiv(a, b):
    # WadRayMath.sol:72-79
    if b == 0 or a > (U256 - 1 - b // 2) // RAY:
        raise Revert("rayDiv overflow/zero")
    return (a * RAY + b // 2) // b


def mulDiv(a, b, c, ceil=False):
    # OZ Math.mulDiv, exact
    if c == 0:
        raise Revert("mulDiv by zero")
    q, r = divmod(a * b, c)
    if q >= U256:
        raise Revert("mulDiv overflow")
    if ceil and r:
        q += 1
    return q


def rayPow(a, n):
    # WadRayMath.sol:96-105
    c = RAY
    while n > 0:
        if n & 1 == 1:
            c = rayMul(c, a)
        n >>= 1
        if n > 0:
            a = rayMul(a, a)
    return c


def rayLn(x, stats=None):
    # WadRayMath.sol:128-149
    if x <= RAY:
        return 0
    k = 0
    while x >= 2 * RAY:
        x //= 2
        k += 1
    z = x - RAY
    v = mulDiv(z, RAY, 2 * RAY + z)
    v2 = rayMul(v, v)
    term = v
    s = v
    n = 3
    iters = 0
    while n < 64:
        term = rayMul(term, v2)
        iters += 1
        if term < n:
            break
        s += term // n
        n += 2
    if stats is not None:
        stats["k_max"] = max(stats.get("k_max", 0), k)
        stats["iters_max"] = max(stats.get("iters_max", 0), iters)
        stats["n_last_max"] = max(stats.get("n_last_max", 0), n)
    return 2 * s + k * LN2_RAY


def rayExp_raw(x, stats=None):
    """Returns (unshifted_exp, k). Caller applies the shift so we can observe overflow."""
    # WadRayMath.sol:154-167
    if x == 0:
        return RAY, 0
    k = x // LN2_RAY
    r = x % LN2_RAY
    e = RAY
    term = RAY
    n = 1
    iters = 0
    while n < 48:
        term = mulDiv(term, r, n * RAY)
        iters += 1
        if term == 0:
            break
        e += term
        n += 1
    if stats is not None:
        stats["iters_max"] = max(stats.get("iters_max", 0), iters)
        stats["n_last_max"] = max(stats.get("n_last_max", 0), n)
        stats["k_max"] = max(stats.get("k_max", 0), k)
    return e, k


def rayExp(x, stats=None):
    e, k = rayExp_raw(x, stats)
    return (e << k) % U256  # `exp <<= k` is unchecked in Solidity


def rayExp_wraps(x):
    e, k = rayExp_raw(x)
    return (e << k) >= U256


def rayPowRay(base, exp):
    # WadRayMath.sol:114-123
    if exp == 0 or base == RAY:
        return RAY
    if exp == RAY:
        return base
    integer = exp // RAY
    c = RAY if integer == 0 else rayPow(base, integer)
    frac = exp % RAY
    if frac == 0:
        return c
    return rayMul(c, rayExp(rayMul(frac, rayLn(base))))


def compounded(rate, dt):
    # MathUtils.sol:43-78 (all floors, unchecked blocks cannot overflow for sane inputs)
    if dt == 0:
        return RAY
    expMinusOne = dt - 1
    expMinusTwo = dt - 2 if dt > 2 else 0
    basePowerTwo = rayMul(rate, rate) // (SPY * SPY)
    basePowerThree = rayMul(basePowerTwo, rate) // SPY
    secondTerm = dt * expMinusOne * basePowerTwo // 2
    thirdTerm = dt * expMinusOne * expMinusTwo * basePowerThree // 6
    return RAY + (rate * dt) // SPY + secondTerm + thirdTerm


def growIndex(lastLocal, lastGlobal, globalNow, multiplier):
    # FloatingMarket.sol:195-202
    if lastGlobal == 0 or globalNow <= lastGlobal:
        return lastLocal
    return rayMul(lastLocal, rayPowRay(rayDiv(globalNow, lastGlobal), multiplier))


# ---------------------------------------------------------------------------
# Exact references
# ---------------------------------------------------------------------------
def exact_ln(x):
    return mpln(mpf(x) / RAY) * RAY


def exact_exp(x):
    return mpexp(mpf(x) / RAY) * RAY


def exact_pow(b, e):
    return mppower(mpf(b) / RAY, mpf(e) / RAY) * RAY


class ErrStats:
    def __init__(self, name):
        self.name = name
        self.n = 0
        self.max_rel = mpf(0)
        self.max_rel_at = None
        self.max_abs = mpf(0)
        self.max_abs_at = None
        self.min_signed = mpf(0)   # most negative (impl - exact) in wei
        self.min_signed_at = None
        self.max_signed = mpf(0)   # most positive
        self.max_signed_at = None
        self.pos = 0
        self.neg = 0
        self.zero = 0

    def add(self, impl, exact, at):
        self.n += 1
        d = mpf(impl) - exact
        rel = abs(d) / exact if exact != 0 else abs(d)
        if rel > self.max_rel:
            self.max_rel, self.max_rel_at = rel, at
        if abs(d) > self.max_abs:
            self.max_abs, self.max_abs_at = abs(d), at
        if d < self.min_signed:
            self.min_signed, self.min_signed_at = d, at
        if d > self.max_signed:
            self.max_signed, self.max_signed_at = d, at
        if d > mpf("0.5"):
            self.pos += 1
        elif d < mpf("-0.5"):
            self.neg += 1
        else:
            self.zero += 1

    def report(self):
        log(f"  [{self.name}] n={self.n}")
        log(f"    max rel err   = {mp.nstr(self.max_rel, 6)}  at {self.max_rel_at}")
        log(f"    max abs err   = {mp.nstr(self.max_abs, 8)} wei  at {self.max_abs_at}")
        log(f"    signed range  = [{mp.nstr(self.min_signed, 8)}, {mp.nstr(self.max_signed, 8)}] wei "
            f"(impl - exact)")
        log(f"    impl > exact (>0.5 wei): {self.pos}   impl < exact: {self.neg}   |d|<=0.5: {self.zero}")
        side = ("one-sided LOW (never over-estimates by >0.5 wei)" if self.pos == 0
                else "one-sided HIGH" if self.neg == 0 else "two-sided")
        log(f"    => {side}")


# ---------------------------------------------------------------------------
# Section 1: rayLn
# ---------------------------------------------------------------------------
def section_rayLn(points, rng):
    log("=" * 78)
    log("1. rayLn(x) vs RAY*ln(x/RAY)")
    st = ErrStats("rayLn, x log-uniform in [RAY, 1e40]")
    st_near = ErrStats("rayLn, x = RAY + z, z log-uniform in [1, 1e26]")
    st_exact_wei = {}
    stats = {}
    # boundaries
    boundary = [RAY, RAY + 1, RAY + 2, RAY + 3, RAY + 4, RAY + 10, RAY + 100,
                2 * RAY - 1, 2 * RAY, 2 * RAY + 1, 3 * RAY, 4 * RAY - 1, 4 * RAY,
                10**28, 10**30, 10**40, 10**50, 10**60, 10**70, U256 - 1]
    log("  boundary table (x, rayLn, exact, impl-exact wei):")
    for x in boundary:
        v = rayLn(x, stats)
        ex = exact_ln(x)
        log(f"    x={x:<80d} ln={v:<30d} exact={mp.nstr(ex, 30):<34} d={mp.nstr(mpf(v) - ex, 6)}")
        if x > RAY:
            st.add(v, ex, x)
    for _ in range(points):
        x = int(10 ** rng.uniform(27, 40))
        if x <= RAY:
            continue
        st.add(rayLn(x, stats), exact_ln(x), x)
    for _ in range(points // 4):
        z = int(10 ** rng.uniform(0, 26))
        x = RAY + z
        st_near.add(rayLn(x, stats), exact_ln(x), x)
    st.report()
    st_near.report()
    log(f"  loop stats: max k (halvings) = {stats['k_max']}, max series iterations = {stats['iters_max']}, "
        f"max n reached = {stats['n_last_max']}")
    # loop count for the largest possible x
    s2 = {}
    rayLn(U256 - 1, s2)
    log(f"  x = 2^256-1: k = {s2['k_max']} halvings, series iterations = {s2['iters_max']} (bounded, no DoS)")
    # early-exit correctness: does `if (term < n) break` ever drop a nonzero term/n?
    # Since term_{n+2} = rayMul(term_n, v2) <= term_n when v2 < RAY, and term_n < n => term_n / n == 0
    # and term_{n+2} / (n+2) <= term_n/(n+2) == 0, the exit drops only zero contributions. Verify
    # empirically by running the loop to n=63 without the break and comparing.
    def rayLn_nobreak(x):
        if x <= RAY:
            return 0
        k = 0
        while x >= 2 * RAY:
            x //= 2
            k += 1
        z = x - RAY
        v = mulDiv(z, RAY, 2 * RAY + z)
        v2 = rayMul(v, v)
        term = v
        s = v
        for n in range(3, 64, 2):
            term = rayMul(term, v2)
            s += term // n
        return 2 * s + k * LN2_RAY
    mism = 0
    for _ in range(200000):
        x = int(10 ** rng.uniform(27, 28.5))
        if rayLn(x) != rayLn_nobreak(x):
            mism += 1
    for x in boundary:
        if rayLn(x) != rayLn_nobreak(x):
            mism += 1
    log(f"  early-exit check: {mism} mismatches between break/no-break variants over 200k+boundary points "
        f"({'exit is lossless' if mism == 0 else 'EXIT DROPS TERMS'})")
    # monotonicity near the halving boundary
    log("  monotonicity around x = 2*RAY (halving boundary):")
    prev = None
    viol = []
    for x in range(2 * RAY - 5, 2 * RAY + 6):
        v = rayLn(x)
        if prev is not None and v < prev:
            viol.append((x, prev, v))
        prev = v
        log(f"    x=2RAY{x - 2*RAY:+d}: {v}")
    log(f"  monotonicity violations at boundary: {viol}")
    # random adjacent monotonicity
    viol = 0
    worst = 0
    for _ in range(points // 4):
        x = int(10 ** rng.uniform(27, 32))
        d = rng.choice([1, 2, 3, 10, 1000])
        a, b = rayLn(x), rayLn(x + d)
        if b < a:
            viol += 1
            worst = max(worst, a - b)
    log(f"  random adjacent monotonicity (x, x+d): {viol} violations, worst drop {worst} wei")


# ---------------------------------------------------------------------------
# Section 2: rayExp
# ---------------------------------------------------------------------------
def section_rayExp(points, rng):
    log("=" * 78)
    log("2. rayExp(x) vs RAY*exp(x/RAY)")
    st = ErrStats("rayExp, x uniform in [0, LN2)  (k = 0, the only reachable band with base < 2)")
    st_wide = ErrStats("rayExp, x uniform in [0, 53e27]  (k up to 76, reachable bound from _growIndex)")
    st_full = ErrStats("rayExp, x uniform in [0, 115e27]  (up to the wrap)")
    stats = {}
    boundary = [0, 1, 2, 10, 10**9, 10**18, RAY - 1, RAY, RAY + 1, 2 * 10**27, LN2_RAY - 1, LN2_RAY,
                LN2_RAY + 1, 2 * LN2_RAY, 10 * RAY, 50 * RAY, 100 * RAY]
    log("  boundary table (x, rayExp, exact, impl-exact wei):")
    for x in boundary:
        v = rayExp(x, stats)
        ex = exact_exp(x)
        log(f"    x={x:<30d} exp={v:<40d} exact={mp.nstr(ex, 32):<36} d={mp.nstr(mpf(v) - ex, 6)}")
        if x > 0:
            st_full.add(v, ex, x)
    for _ in range(points):
        x = rng.randrange(0, LN2_RAY)
        st.add(rayExp(x, stats), exact_exp(x), x)
    for _ in range(points // 4):
        x = rng.randrange(0, 53 * RAY)
        st_wide.add(rayExp(x, stats), exact_exp(x), x)
    for _ in range(points // 4):
        x = rng.randrange(0, 115 * RAY)
        st_full.add(rayExp(x, stats), exact_exp(x), x)
    st.report()
    st_wide.report()
    st_full.report()
    log(f"  loop stats: max series iterations = {stats['iters_max']}, max n reached = {stats['n_last_max']}, "
        f"max k = {stats['k_max']}")
    # smallest x at which `exp <<= k` wraps
    lo, hi = 100 * RAY, 200 * RAY
    assert not rayExp_wraps(lo) and rayExp_wraps(hi)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if rayExp_wraps(mid):
            hi = mid
        else:
            lo = mid
    e, k = rayExp_raw(hi)
    log(f"  smallest x with (exp << k) >= 2^256: x = {hi} (= {mp.nstr(mpf(hi)/RAY, 12)} in real units), "
        f"k = {k}, unshifted exp = {e}")
    log(f"    rayExp({hi}) wraps to {rayExp(hi)} (true value ~ {mp.nstr(exact_exp(hi), 8)})")
    log(f"    rayExp({hi-1}) = {rayExp(hi-1)} (no wrap)")
    # reachability from _growIndex: x = rayMul(frac, rayLn(base)) with frac < RAY and base = rayDiv(gNow, gLast)
    # rayDiv reverts if a > (2^256 - b/2) / RAY, so gNow <= that; gLast >= RAY => base <= (2^256-1)//RAY
    base_max = (U256 - 1 - RAY // 2) // RAY  # largest globalNow accepted by rayDiv with lastGlobal=RAY
    ln_max = rayLn(base_max)
    log(f"  reachability: max base out of rayDiv (lastGlobal = RAY, globalNow = rayDiv bound) = {base_max}")
    log(f"    rayLn(base_max) = {ln_max} (= {mp.nstr(mpf(ln_max)/RAY, 8)} real); the rayExp argument is "
        f"rayMul(frac, rayLn(base)) < {ln_max} < {hi} => wrap UNREACHABLE from _growIndex; "
        f"k <= {ln_max // LN2_RAY}")
    # but rayPow(base, integer) reverts earlier for multiplier >= 2e27
    sq_max = int((U256 - 1 - HALF_RAY) ** 0.5)
    log(f"    with multiplier >= 2e27, rayPow(base,2) = rayMul(base,base) reverts once base > ~{sq_max:.3e} "
        f"(index growth > {sq_max/RAY:.3e}x between two charges); revert, not wrap")


# ---------------------------------------------------------------------------
# Section 3: rayPow / rayPowRay
# ---------------------------------------------------------------------------
def section_rayPowRay(points, rng):
    log("=" * 78)
    log("3. rayPowRay(base, exp) vs (base/RAY)^(exp/RAY)")
    st_a = ErrStats("rayPowRay, base=RAY+z (z log-uniform [1,1e27]), exp uniform [0, 2e27]")
    st_b = ErrStats("rayPowRay, base log-uniform [RAY, 1e30], exp uniform [0, 2e27]")
    st_c = ErrStats("rayPowRay, base=RAY+z (z log-uniform [1,1e24]), exp=1.5e27  (realistic band)")
    st_pow = ErrStats("rayPow, a log-uniform [RAY, 1e28], n in [1, 4]")
    boundary_b = [RAY, RAY + 1, RAY + 2, 2 * RAY - 1, 2 * RAY, 10**30, 10**40]
    boundary_e = [0, 1, RAY - 1, RAY, RAY + 1, 15 * 10**26, 2 * 10**27]
    log("  boundary grid (base, exp) -> rayPowRay, exact, d wei:")
    i28_viol = []
    for b in boundary_b:
        for e in boundary_e:
            try:
                v = rayPowRay(b, e)
            except Revert as r:
                log(f"    base={b} exp={e}: REVERT ({r})")
                continue
            ex = exact_pow(b, e)
            log(f"    base={b:<42d} exp={e:<28d} -> {v:<45d} exact={mp.nstr(ex, 30):<34} d={mp.nstr(mpf(v)-ex, 6)}")
            if v < RAY or (e >= RAY and v < b):
                i28_viol.append((b, e, v))
    for _ in range(points):
        z = int(10 ** rng.uniform(0, 27))
        b = RAY + z
        e = rng.randrange(0, 2 * RAY + 1)
        v = rayPowRay(b, e)
        st_a.add(v, exact_pow(b, e), (b, e))
        if v < RAY or (e >= RAY and v < b):
            i28_viol.append((b, e, v))
    for _ in range(points // 4):
        b = int(10 ** rng.uniform(27, 30))
        e = rng.randrange(0, 2 * RAY + 1)
        try:
            v = rayPowRay(b, e)
        except Revert:
            continue
        st_b.add(v, exact_pow(b, e), (b, e))
        if v < RAY or (e >= RAY and v < b):
            i28_viol.append((b, e, v))
    for _ in range(points // 4):
        z = int(10 ** rng.uniform(0, 24))
        b = RAY + z
        e = 15 * 10**26
        v = rayPowRay(b, e)
        st_c.add(v, exact_pow(b, e), (b, e))
    for _ in range(points // 4):
        a = int(10 ** rng.uniform(27, 28))
        n = rng.randint(1, 4)
        st_pow.add(rayPow(a, n), mppower(mpf(a) / RAY, n) * RAY, (a, n))
    st_a.report()
    st_b.report()
    st_c.report()
    st_pow.report()
    log(f"  I28 violations (result < RAY, or exp>=RAY and result < base): {len(i28_viol)}  {i28_viol[:5]}")
    # structural proof sketch is in A.md; here: monotonicity in base and in exp
    viol_b = 0
    worst_b = 0
    viol_e = 0
    worst_e = 0
    for _ in range(points // 2):
        z = int(10 ** rng.uniform(0, 27))
        b = RAY + z
        e = rng.randrange(0, 2 * RAY + 1)
        d = rng.choice([1, 2, 5, 10**3, 10**9])
        v1, v2 = rayPowRay(b, e), rayPowRay(b + d, e)
        if v2 < v1:
            viol_b += 1
            worst_b = max(worst_b, v1 - v2)
        e2 = min(e + d, 2 * RAY)
        v3 = rayPowRay(b, e2)
        if v3 < v1:
            viol_e += 1
            worst_e = max(worst_e, v1 - v3)
    log(f"  monotonicity in base (b, b+d): {viol_b} violations, worst drop {worst_b} wei")
    log(f"  monotonicity in exp  (e, e+d): {viol_e} violations, worst drop {worst_e} wei")
    # the exp == RAY / frac == 0 discontinuity: rayPowRay(b, RAY) = b exactly, rayPowRay(b, RAY-1)?
    log("  seam at exp = RAY (integer path returns base exactly; RAY-1 goes through ln/exp):")
    for b in [RAY + 1, RAY + 10**9, RAY + 10**18, 11 * 10**26, 2 * RAY, 10**28]:
        lo_, mid, hi_ = rayPowRay(b, RAY - 1), rayPowRay(b, RAY), rayPowRay(b, RAY + 1)
        log(f"    base={b}: f(RAY-1)={lo_}  f(RAY)={mid}  f(RAY+1)={hi_}   "
            f"exact(RAY-1)={mp.nstr(exact_pow(b, RAY-1), 30)}")


# ---------------------------------------------------------------------------
# Section 4: I29 differential — one _growIndex step vs n steps over the same interval
# ---------------------------------------------------------------------------
def section_growIndex(rng):
    log("=" * 78)
    log("4. I29: _growIndex one step vs n steps over the same global-index interval")
    log("   local index starts at RAY; global path G_i = round(G_0 * (1+g)^(i/n)) (integer ray);")
    log("   'one' = _growIndex(RAY, G_0, G_n, m); 'split' = fold over consecutive pairs.")
    log("   d = split - one in wei of the local index (negative => splitting accrues less).")
    header = f"  {'mult':>8} {'growth':>7} {'n':>6} {'one':>32} {'split':>32} {'d wei':>8} {'rel':>10} {'exact':>32}"
    log(header)
    rows = []
    csv = open(os.path.join(OUT_DIR, "growindex_split.csv"), "w")
    csv.write("multiplier,growth,n,one,split,d_wei,rel,exact\n")
    for m in [RAY, 15 * 10**26, 2 * RAY, 125 * 10**25, 1999 * 10**24]:
        for g in [0.01, 0.05, 0.10, 0.25, 0.50]:
            G0 = RAY
            gm = mpf(1) + mpf(g)
            exact = mppower(gm, mpf(m) / RAY) * RAY
            for n in [1, 2, 10, 100, 1000, 8760, 30000]:
                path = [G0] + [int(mp.nint(G0 * mppower(gm, mpf(i) / n))) for i in range(1, n + 1)]
                one = growIndex(RAY, path[0], path[-1], m)
                loc = RAY
                lastG = path[0]
                for i in range(1, n + 1):
                    loc = growIndex(loc, lastG, path[i], m)
                    lastG = path[i]
                d = loc - one
                rel = mpf(d) / one
                rows.append((m, g, n, one, loc, d, rel))
                log(f"  {mp.nstr(mpf(m)/RAY, 4):>8} {g:>7.2f} {n:>6} {one:>32} {loc:>32} {d:>8} {mp.nstr(rel, 4):>10} "
                    f"{mp.nstr(exact, 30):>32}")
                csv.write(f"{m},{g},{n},{one},{loc},{d},{mp.nstr(rel, 6)},{mp.nstr(exact, 32)}\n")
    csv.close()
    neg = sum(1 for r in rows if r[5] < 0)
    pos = sum(1 for r in rows if r[5] > 0)
    zer = sum(1 for r in rows if r[5] == 0)
    worst = min(rows, key=lambda r: r[5])
    worst_pos = max(rows, key=lambda r: r[5])
    log(f"  split < one: {neg}   split > one: {pos}   equal: {zer}")
    log(f"  most negative d: {worst[5]} wei at m={worst[0]}, g={worst[1]}, n={worst[2]}  (rel {mp.nstr(worst[6], 4)})")
    log(f"  most positive d: {worst_pos[5]} wei at m={worst_pos[0]}, g={worst_pos[1]}, n={worst_pos[2]}")
    # per-step error bound: measure |growIndex(L, G, G', m) - exact| over random small steps
    log("  per-step error of _growIndex vs exact (L=RAY, random step growth 1e-9..1e-2, random m in [1e27,2e27]):")
    worst_d = 0
    worst_at = None
    pos = neg = 0
    for _ in range(50000):
        G0 = int(10 ** rng.uniform(27, 28))
        step = 10 ** rng.uniform(-9, -2)
        G1 = int(G0 * (1 + step))
        if G1 <= G0:
            continue
        m = rng.randrange(RAY, 2 * RAY + 1)
        v = growIndex(RAY, G0, G1, m)
        ex = mppower(mpf(G1) / G0, mpf(m) / RAY) * RAY
        d = mpf(v) - ex
        if d > 0.5:
            pos += 1
        elif d < -0.5:
            neg += 1
        if abs(d) > worst_d:
            worst_d, worst_at = abs(d), (G0, G1, m, v, mp.nstr(ex, 30))
    log(f"    worst |d| = {mp.nstr(worst_d, 5)} wei at {worst_at};  over: {pos}, under: {neg}")
    # random fractional multiplier and random interval, many steps: signed drift per step
    log("  drift per step, fractional multipliers (m in {1.5e27, 1.25e27, 1.75e27}), 12-second steps at 10%/yr:")
    for m in [15 * 10**26, 125 * 10**25, 175 * 10**25]:
        n = 20000
        G = RAY
        loc = RAY
        ex_loc = mpf(RAY)
        rate = mpf("0.10")
        for i in range(n):
            G1 = int(mp.nint(RAY * mpexp(rate * (i + 1) * 12 / SPY)))
            loc = growIndex(loc, G, G1, m)
            G = G1
        ex = mppower(mpf(G) / RAY, mpf(m) / RAY) * RAY
        log(f"    m={mp.nstr(mpf(m)/RAY,4)}: after {n} steps local={loc}, exact={mp.nstr(ex, 30)}, "
            f"d={mp.nstr(mpf(loc)-ex, 6)} wei ({mp.nstr((mpf(loc)-ex)/n, 4)} wei/step)")


# ---------------------------------------------------------------------------
# Section 5: MathUtils cubic vs exact compounding
# ---------------------------------------------------------------------------
def section_mathutils():
    log("=" * 78)
    log("5. MathUtils.calculateCompoundedInterest (3-term binomial, all floors) vs exp(rate*t)")
    log("   ratio = cubic / exact; shortfall = 1 - ratio (borrower under-charged, lender/underwriter under-paid)")
    log(f"  {'rate':>6} {'period':>8} {'cubic':>34} {'exact':>34} {'shortfall':>12}")
    csv = open(os.path.join(OUT_DIR, "mathutils_cubic.csv"), "w")
    csv.write("rate,period_days,cubic,exact,shortfall\n")
    for r in [0.05, 0.5, 1.0, 5.0]:
        rate = int(r * RAY)
        for days in [1, 30, 365, 5 * 365]:
            dt = days * 86400
            c = compounded(rate, dt)
            ex = mpexp(mpf(rate) * dt / SPY / RAY) * RAY
            sf = 1 - mpf(c) / ex
            log(f"  {r:>6.2f} {days:>6d}d {c:>34d} {mp.nstr(ex, 30):>34} {mp.nstr(sf, 6):>12}")
            csv.write(f"{r},{days},{c},{mp.nstr(ex, 34)},{mp.nstr(sf, 8)}\n")
    csv.close()
    log("  direction: every term of the Taylor series is positive and the cubic truncates + floors,")
    log("  so cubic <= (1+x)^n <= e^(nx): ALWAYS under. Borrowers under-charged; premium recipients under-paid.")
    log("  the liquidity index is re-checkpointed on every stablecoin mint/burn/deposit/withdraw so its")
    log("  single-interval dt is short; the underwriter index is checkpointed ONLY by updateUnderwriterRate.")
    # marginal-rate view: what the 1-day premium looks like t years into an un-checkpointed underwriter index
    log("  underwriter index: 1-day increment as % of exact, t years after the last updateUnderwriterRate:")
    for r in [0.2, 1.0]:
        rate = int(r * RAY)
        for years in [0, 1, 2, 5]:
            t0 = years * SPY
            t1 = t0 + 86400
            c0, c1 = compounded(rate, t0), compounded(rate, t1)
            inc = mpf(c1) / c0 - 1  # what _premium charges: index ratio over the day
            ex = mpexp(mpf(rate) * 86400 / SPY / RAY) - 1
            log(f"    rate={r:.2f} t={years}y: daily increment cubic={mp.nstr(inc, 8)} exact={mp.nstr(ex, 8)} "
                f"ratio={mp.nstr(inc/ex, 6)}")


# ---------------------------------------------------------------------------
# Section 6: rayPow decay for the averaging weight / vesting weight (sanity)
# ---------------------------------------------------------------------------
def section_rayPow_decay():
    log("=" * 78)
    log("6. rayPow decay bases (IRM retention, PremiumVesting retention): error vs exact")
    for name, period in [("IRM averagingPeriod=1h", 3600), ("IRM 1 day", 86400), ("Vesting 12h", 43200)]:
        ret = RAY - RAY // period
        worst = mpf(0)
        for el in [1, 12, 60, 600, 3600, 43200, 86400, 30 * 86400]:
            v = rayPow(ret, el)
            ex = mppower(mpf(ret) / RAY, el) * RAY
            d = mpf(v) - ex
            worst = max(worst, abs(d))
        el_zero = None
        lo, hi = 1, 10**8
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if rayPow(ret, mid) == 0:
                hi = mid
            else:
                lo = mid
        log(f"  {name}: retention={ret}, worst |d| over sample = {mp.nstr(worst, 4)} wei, "
            f"rayPow reaches 0 at elapsed = {hi} s ({hi/86400:.1f} days)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", type=int, default=1_000_000)
    ap.add_argument("--seed", type=int, default=20260914)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    global LOG
    LOG = open(os.path.join(OUT_DIR, "wadray_check.txt"), "w")
    t0 = time.time()
    log(f"wadray_check.py  points={args.points} seed={args.seed} mp.dps={mp.dps}")
    # self-check of the ports against known constants
    assert rayMul(RAY, RAY) == RAY and rayDiv(RAY, RAY) == RAY
    assert rayPow(RAY, 5) == RAY and rayPowRay(RAY, 2 * RAY) == RAY
    assert rayExp(0) == RAY and rayLn(RAY) == 0
    section_rayLn(args.points, rng)
    section_rayExp(args.points, rng)
    section_rayPowRay(args.points, rng)
    section_growIndex(rng)
    section_mathutils()
    section_rayPow_decay()
    log(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
