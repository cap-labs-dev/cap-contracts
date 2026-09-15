# Workstream A — Math (rounding, fixed premium, haircut curve, floating index, transcendentals)

> **Post-verification status (lead, 2026-09-14):** no Medium+ filed; A-1 Low stands. §6 halmos: the workstream was cut off before pasting results; the lead relaunched the run, output in `audit/v3/models/output/halmos_A.log`.


Target `cap-network` @ `a843c1d`. Files read end to end: `contracts/utils/{WadRayMath,MathUtils,PremiumVesting}.sol`,
`contracts/cap/market/{BaseMarket,FloatingMarket,FixedMarket}.sol`, `contracts/cap/{InterestRateModel,Stablecoin,Tranche}.sol`,
`contracts/ERC7540/ERC7540AsyncRedeem.sol`, plus `test/shared/CapDeployer.sol` for the harness.

Deliverables: this file; `audit/v3/tests/scratch/A/{HalmosMath,FloatingRounding,FixedCredit,StablecoinCurve6,VestingAndIrmDust}.t.sol`;
`audit/v3/models/wadray_check.py` with output in `audit/v3/models/output/{wadray_check.txt,growindex_split.csv,mathutils_cubic.csv,forge_A_*.log,halmos_A*.log}`.

Run: `FOUNDRY_TEST=audit/v3/tests/scratch/A forge test --match-path 'audit/v3/tests/scratch/A/*' -vv` (scoped to this directory; other
workstreams' half-written files break the wide compile). Python: `venv/bin/python audit/v3/models/wadray_check.py --points 1000000`.

**Summary: 0 Critical, 0 High, 0 Medium, 1 Low, 7 Informational.** Every money-bearing rounding in scope is either protocol-favourable
or bounded at 1–2 wei; the new transcendental library is bit-exactly modelled and is one-sided low in the reachable band with a worst
case of 149 wei (1.5e-25 relative) on a 27-digit index; the fixed-market sizing invariant I32 is refuted by exactly one wei (fails a
health check only when `ltv == lt` and `buffer == 0`); the Stablecoin haircut curve is exactly invertible in asset units at 6 and 18
decimals and no round trip profits. The one Low is economic, not exploitable: the underwriter index is a single-checkpoint cubic that
under-accrues without bound in time since the last `updateUnderwriterRate` (14 % of nominal after two years at a 100 % rate).

Technique legend used below: **halmos** (symbolic, bounded domain), **fuzz N** (forge, N runs), **Python 1e6** (bit-exact model vs
mpmath at ≥1e6 points), **proof** (argument in this file), **PoC** (deterministic forge test on the real contracts).

---

## 1. Rounding table

Every division / `mulDiv` / `rayMul` / `rayDiv` / `wadDiv` in the in-scope contracts. "Favours" = who gains from the rounding
direction; "OK?" = whether that is the protocol-favourable direction (✓), immaterial-by-construction (≈, ≤1 wei and not exploitable),
or unfavourable (✗). `rayMul`/`rayDiv` are half-up (|error| ≤ 0.5 ulp, either side).

| # | Location | Operation | Rounding | Favours | OK? | Note |
|---|---|---|---|---|---|---|
| 1 | WadRayMath.sol:30-37 `wadMul` | `(a*b+HALF_WAD)/WAD` | half-up | — | ≈ | Aave verbatim; unused in scope |
| 2 | WadRayMath.sol:44-51 `wadDiv` | `(a*WAD+b/2)/b` | half-up | — | ≈ | Aave verbatim; unused in scope |
| 3 | WadRayMath.sol:58-65 `rayMul` | `(a*b+HALF_RAY)/RAY` | half-up | either | ≈ | halmos-checked half-up bound (§6) |
| 4 | WadRayMath.sol:72-79 `rayDiv` | `(a*RAY+b/2)/b` | half-up | either | ≈ | halmos-checked |
| 5 | WadRayMath.sol:96-105 `rayPow` | chain of `rayMul` | half-up ×⌈log2 n⌉ | either | ≈ | ±98.7 wei worst at a ≈ 1e28, n=4 (Python 1e6) |
| 6 | WadRayMath.sol:132-135 `rayLn` | `x /= 2` | floor | borrower | ≈ | ≤1 wei of reduced x per halving; total < 2 wei |
| 7 | WadRayMath.sol:139 `rayLn` | `mulDiv(z, RAY, 2RAY+z)` | floor | borrower | ≈ | v low by <1 wei ⇒ ln low by <2 wei |
| 8 | WadRayMath.sol:140,144 `rayLn` | `rayMul(v,v)`, `rayMul(term,v2)` | half-up | either | ≈ | |
| 9 | WadRayMath.sol:146 `rayLn` | `term / n` | floor | borrower | ≈ | series truncation also drops positive terms ⇒ rayLn one-sided LOW (Python 1e6, 0 over-estimates) |
| 10 | WadRayMath.sol:157-158 `rayExp` | `x / LN2_RAY`, `x % LN2_RAY` | floor | — | ≈ | LN2_RAY is truncated (true ln2 = …121458…) ⇒ over-estimate 4.6e-28·k for k≥1 |
| 11 | WadRayMath.sol:162 `rayExp` | `mulDiv(term, r, n*RAY)` | floor | borrower | ≈ | one-sided LOW for k=0 (Python 1e6), ≤18.3 wei |
| 12 | WadRayMath.sol:166 `rayExp` | `exp <<= k` | **unchecked** | — | ≈ | wraps at x ≥ 115.2758807e27; unreachable (§5) |
| 13 | WadRayMath.sol:122 `rayPowRay` | `rayMul(c, rayExp(rayMul(frac, rayLn(base))))` | mixed | borrower | ≈ | net one-sided LOW in the realistic band (§5) |
| 14 | WadRayMath.sol:173-178 `rayToWad` | `/1e9` + half-up | half-up | — | ≈ | Aave verbatim; unused in scope |
| 15 | MathUtils.sol:25-27 `calculateLinearInterest` | `/SECONDS_PER_YEAR` | floor | borrower | ≈ | unused in scope |
| 16 | MathUtils.sol:64-65,70,74,77 `calculateCompoundedInterest` | 5 floors + cubic truncation | floor | **borrower** | ✗-by-design | always ≤ exact; unbounded shortfall with elapsed time (A-1, §7) |
| 17 | BaseMarket.sol:226 `debtLiquidationThreshold` | `totalCapital().rayMul(lt)` | half-up | borrower | ≈ | threshold up to 0.5 wei high; should be floor (A-4) |
| 18 | BaseMarket.sol:233 `healthiness` | `threshold.rayDiv(debt)` | half-up | borrower | ≈ | reports 1e27 for debt = threshold+1 once debt ≥ 2e27 (PoC, A-4) |
| 19 | BaseMarket.sol:240 `utilization` | `rayDiv` | half-up | — | ≈ | view only |
| 20 | BaseMarket.sol:250 `maxLiquidatable` | `_slashPerDebt().rayMul(lt)` | half-up | liquidator | ≈ | perCleared ≤0.5 wei low ⇒ liquidatable ≤1 wei high |
| 21 | BaseMarket.sol:251 `maxLiquidatable` | `targetHealth.rayMul(debt)`, `.rayDiv(perCleared)` | half-up | liquidator | ≈ | ±1 wei on the repayment that lands on targetHealth |
| 22 | BaseMarket.sol:259 `recoverableDebt` | `totalCapital().rayDiv(1+bonus)` | half-up | borrower | ≈ | unrecoverable ≤1 wei low ⇒ guardian may write off 1 wei less |
| 23 | BaseMarket.sol:277 `lockedValue` | `mulDiv(debt, RAY, lt-buffer, Ceil)` | **ceil** | protocol | ✓ | |
| 24 | BaseMarket.sol:321 `variableCreditLimit` | `Σactive.rayMul(min(ltv,lt))` | half-up | borrower | ≈ | credit ≤0.5 wei high; should be floor (A-4) |
| 25 | BaseMarket.sol:362 `_liquidate` | `repaid.rayMul(1+bonus)` | half-up | liquidator | ≈ | ≤0.5 wei USD over-slash |
| 26 | BaseMarket.sol:455 `_chargePremium` | `uwPremium.rayMul(weight)` | half-up | junior tranche | ✓ | capped by `remaining`; remainder to senior ⇒ Σ == uwPremium exactly |
| 27 | FloatingMarket.sol:117,140,142 `totalDebt`/`index` | `scaledDebt.rayMul(L.rayMul(U))` | half-up | either | ≈ | the same product is used by `_premium` ⇒ telescopes exactly (§4, halmos/fuzz) |
| 28 | FloatingMarket.sol:151 `_borrowWithin` | `mulDiv(current+req, RAY, idx, Floor)` | **floor** | protocol | ✓ | minted ≤ requested; shortfall ≤ ⌊idx/RAY⌋+1 (I31) |
| 29 | FloatingMarket.sol:164 `_repayWithin` | `mulDiv(debt-req, RAY, idx, Ceil)` | **ceil** | protocol | ✓ | burned ≤ requested; shortfall ≤ ⌊idx/RAY⌋+1; reverts when requested < ⌊idx/RAY⌋+2 can round to 0 (A-2) |
| 30 | FloatingMarket.sol:201 `_growIndex` | `globalNow.rayDiv(lastGlobal)` then `rayPowRay`, `rayMul` | half-up + #13 | borrower | ≈ | ≤14.3 wei/step worst, −1.3…−3.0 wei/step typical (§4) |
| 31 | FloatingMarket.sol:222-224 `_premium` | three `rayMul` chains | half-up | — | ✓ | identical to the getter ⇒ liq+uw == Δdebt exactly |
| 32 | FixedMarket.sol:202 `availableCredit` | `(prior*term).rayMul(Δrate)/SPY` | half-up then **floor** | borrower | ✗ (1 wei) | catch-up under-sized ⇒ debt = limit+1 possible (A-3) |
| 33 | FixedMarket.sol:261 `_ratesStillToMint` | `term.rayDiv(maximumTermLimit)` | half-up | either | ≈ | termUtilization ±0.5 ulp |
| 34 | FixedMarket.sol:262 `_ratesStillToMint` | `liquidityRate.rayMul(multiplier)` | half-up | either | ≈ | |
| 35 | FixedMarket.sol:295 `_principalWithin` | `(term*rate)/SPY` then `mulDiv(limit,1e27,1e27+q)` | floor / floor | borrower / protocol | ≈ | net ≤1 wei over for P < 1e27 wei (§2) |
| 36 | FixedMarket.sol:397-398 `_premium` | `cumulativeDebt.rayMul(rate)/SPY` ×2 | half-up then floor | borrower | ≈ | each component ≤1 wei low; multiply-before-divide, single division |
| 37 | InterestRateModel.sol:162,170 `fixedRatesAfterMint`/`termMultiplier` | `rayMul` | half-up | either | ≈ | |
| 38 | InterestRateModel.sol:201 `_setAveragingPeriod` | `1e27 / period` | floor | — | ≈ | retention ≤1 wei high |
| 39 | InterestRateModel.sol:271 `_averagingWeight` | `retention.rayPow(elapsed)` | half-up chain | — | ≈ | ≤157 wei (1h period) / 2354 wei (1d) vs exact; reaches 0 after 2.6 d / 62.9 d (Python) |
| 40 | InterestRateModel.sol:281-282 `_carry` | `rayMul(weight)` | half-up | — | ✓ | order-preserving: avgCredit ≤ avgSupply is invariant (fuzz 20k, proof §7) |
| 41 | InterestRateModel.sol:291 `_ratio` | `credit.rayDiv(supply)` | half-up | — | ≈ | ≤ 1e27 given #40 and I35 |
| 42 | InterestRateModel.sol:300,304 `_nextLiquidityRate` | `rayDiv(kink)`, `rayDiv(1e27-kink)` | half-up | — | ≈ | `kink == 1e27` accepted; divisor 0 only if utilization > 1e27, which needs I35 broken (§7 note) |
| 43 | InterestRateModel.sol:315 `_index` | `index.rayMul(compounded)` | half-up | — | ≈ | monotone nondecreasing (fuzz 100k on real IRM, proof §4) |
| 44 | Stablecoin.sol:148 `_utilizationRate` | `rayDiv` | half-up | — | ≈ | |
| 45 | Stablecoin.sol:190 `unlockedSupply` | `_quoteWithdraw(balance)` | ceil (#54) | protocol | ✓ | `convertToAssets(unlockedSupply()) ≤ balance` (fuzz 20k) |
| 46 | Stablecoin.sol:201 `totalAssets` | `mulDiv(backing, 10^ud, 1e18)` | floor | — | ≈ | view |
| 47 | Stablecoin.sol:212 `previewDeposit` | `mulDiv(assets, 1e18, 10^ud, Floor)` | floor | protocol | ✓ | exact for ud ≤ 18 |
| 48 | Stablecoin.sol:223 `previewMint` | `mulDiv(shares, 10^ud, 1e18, Ceil)` | ceil | protocol | ✓ | |
| 49 | Stablecoin.sol:256 `_convertToAssets` | `mulDiv(remaining, anchor, anchor+remaining*B, opposite)` | opposite of caller | protocol (Floor path) | ✓ | only the Floor path is reachable (`convertToAssets`, `redeem`, `instantRedeem`); the Ceil path has no caller since `previewMint`/`previewWithdraw` are overridden |
| 50 | Stablecoin.sol:260 `_convertToAssets` | `mulDiv(value, 10^ud, 1e18, rounding)` | floor (reachable) | protocol | ✓ | 1e12 share-wei pays 0 at any haircut (worked example) |
| 51 | Stablecoin.sol:274 `_convertToShares` | `mulDiv(assets, 1e18, 10^ud, rounding)` | ceil (reachable) | protocol | ✓ | Floor path only via the `convertToShares` view |
| 52 | Stablecoin.sol:285 `_convertToShares` | `mulDiv(retained, anchor, anchor-retained*B, opposite)` | floor under Ceil caller | protocol | ✓ | denominator ≥ R²+B > 0 (proof §3) |
| 53 | Stablecoin.sol:322 `_onWithdraw` | `mulDiv(assets, 1e18, 10^ud)` | floor | — | ✓ | exact for ud ≤ 18; the L324 cap binds only within one asset-wei of clearing bad debt (§3) |
| 54 | ERC7540AsyncRedeem.sol:361-363 `_quoteWithdraw` | `_convertToShares(assets, Ceil)` | ceil | protocol | ✓ | |
| 55 | ERC7540AsyncRedeem.sol:139,156,184,251,278,288 | `convertToAssets` (OZ Floor) | floor | protocol | ✓ | |
| 56 | Tranche.sol:79 `slash` | `mulDiv(value, unit, price)` | floor | tranche | ✓ | delivers ≤ requested |
| 57 | Tranche.sol:83 `slash` | `mulDiv(assets, price, unit)` | floor | liquidator | ≈ | reports ≤ delivered ⇒ next tranche asked for ≤1 wei USD extra (P10, WS-D) |
| 58 | Tranche.sol:171-172 `unlockedSupply` | `mulDiv(locked, unit, price, Ceil)` then `_quoteWithdraw` (OZ Ceil) | ceil ×2 | protocol | ✓ | |
| 59 | Tranche.sol:180,187 `totalCapital`/`activeCapital` | `assets*price/unit` | floor | protocol | ✓ | understates collateral |
| 60 | PremiumVesting.sol:78 `premiumPerSecond` | `/VESTING_PERIOD` | floor | — | ≈ | view |
| 61 | PremiumVesting.sol:242,304 `_accrue`/`_projectedPerShare` | `mulDiv(amount, RAY, supply, Floor)` | floor | contract | ✓ | strands < supply/RAY wei per accrual (§7: 1 wei over 2000 accruals) |
| 62 | PremiumVesting.sol:315 `_vested` | `mulDiv(remainder, weight, RAY, Floor)` | floor | contract | ✓ | remainder < ~3600 wei does not vest under 12-s poking; vests fully after 31.4 d idle |
| 63 | PremiumVesting.sol:323 `_owed` | `mulDiv(perShare, balance, RAY, Floor)` | floor | contract | ✓ | MasterChef pattern; monotone ⇒ no underflow at L257/271 |
| 64 | PremiumVesting.sol:330 `_weight` | `RAY / VESTING_PERIOD` | floor | — | ≈ | discrete (1−1/T)^t vs e^{−t/T}: 5.7e-6 relative after 24000 s, by definition not rounding |

**Half-up where a direction was required (task item).** Rows 17, 18, 22, 24 round in the borrower's favour by ≤ 1 wei
(`debtLiquidationThreshold`, `healthiness`, `recoverableDebt`, `variableCreditLimit`); row 20/21/25 in the liquidator's favour by
≤ 1 wei (`_slashPerDebt().rayMul(lt)`, `maxLiquidatable`, `toSlash`); row 26 (`_premium` split by weight) is conservation-exact
because the remainder is routed rather than rounded; row 27 (`totalCapital`-adjacent `totalDebt`) is consistent with `_premium`.
None is exploitable — the largest observable effect is A-4 (`healthiness()` masking a 1-wei excess at ≥ 2e27 wei of debt) — but
rows 17/18/24 should be `mulDiv(..., Floor)` on principle, and row 22 `Ceil`. See A-4.

**Multiply-before-divide and intermediate overflow bounds (task item).**
- `FixedMarket._premium` L396: `chargeableDebt * term` is a checked product; `rayMul` then reverts if `cumulativeDebt > (2^256−HALF)/rate`.
  With `chargeableDebt ≤ 1e30` (1e12 cUSD), `term ≤ 3.2e9` s (100 years) and `rate ≤ 1e29` (10,000 %/yr): `1e30·3.2e9·1e29 = 3.2e68 < 1.16e77`. Safe by 8 orders. Only one division (`/SPY`) after one half-up ⇒ ≤ 1 wei low per component.
- `FixedMarket.availableCredit` L202: `prior * term` with `prior ≤ totalSupply`: same bound. Safe.
- `FixedMarket._principalWithin` L295: `term * rate` ≤ 3.2e38, no overflow; `mulDiv` 512-bit. `maximumTermLimit` has no upper bound in `_setTermLimits` (L301-308); a governor setting it above ~2^256/rate makes `term*rate` revert — governor-only, noted.
- `Stablecoin._convertToAssets/Shares` L253/L284: `supply * recognized` ≤ S² overflows only for S > 3.4e38 wei = 3.4e20 cUSD. Unreachable. `remaining * shortfall`, `retained * shortfall` likewise. `mulDiv(remaining, anchor, …)` is 512-bit.
- `MathUtils.calculateCompoundedInterest` L68/72: `exp * expMinusOne * expMinusTwo * basePowerThree` with `exp ≤ 3.2e9`, `basePowerThree ≤ rate³/(RAY²·SPY³)`: at `rate = 1e29` (10,000 %) `basePowerThree = 3.2e10`, product `1e30·3.2e10 = 3.2e40`. Safe. The `unchecked` blocks only wrap divisions.
- `Tranche.totalCapital` L180: `assets * price` with 18-dec assets ≤ 1e30 and price ≤ 1e26 (1e8 USD): 1e56. Safe.
- `rayLn` L132: the halving loop runs ⌊log2(x/RAY)⌋ ≤ 166 iterations at `x = 2^256−1`; the series ≤ 31 iterations (observed max 26). Bounded, no DoS (Python).

---

## 2. Fixed-market premium — `_borrowPremium`, `_premiumStillToMint`, `_principalWithin`, `availableCredit(term)` (I32)

**Derivation.** Let `r(m)` = combined annual rate after minting `m` more credit-backed supply
(`_termRate(term, m)` = `liq(m)·mult + uw`, L284-287) and `f(P) = ⌊rayMul((prior+P)·term, r(P)) / SPY⌋` per component
(L391-399), `prior = unsmoothedCredit()` = live credit not yet absorbed by the utilization average.

- `_borrowPremium(P, term)` (L337-351) = `f(P) − f(0)` per component, clamped at 0. With `prior = 0` it is `premium(P, r(P))`.
- `availableCredit(term)` (L186-208): `limit = creditLimit − totalDebt`; `rate = r(limit)` (worst case: the rate after minting the
  whole limit); `catchUp = ⌊rayMul(prior·term, r(limit) − r(0)) / SPY⌋`; `limit' = limit − catchUp`; `credit = _principalWithin(limit', term, r(limit))`
  `= ⌊limit'·1e27 / (1e27 + ⌊term·rate/SPY⌋)⌋`, the largest `P` with `P + P·term·rate/SPY ≤ limit'`.
- Claim: for `P ≤ credit`, `totalDebt_after = totalDebt + P + (f(P) − f(0)) ≤ creditLimit`. Ideal arithmetic: `f(P) − f(0) =
  P·term·r(P)/SPY + prior·term·(r(P) − r(0))/SPY ≤ P·term·r(limit)/SPY + catchUp_ideal` because `r` is monotone in the mint
  amount (`averageUtilizationAfterMint` is `(c+e+m)/(s+e+m)`, increasing in `m` for `c+e ≤ s+e`; `_nextLiquidityRate` is
  monotone in utilization with non-negative slopes). So `P + premium ≤ limit' + catchUp = limit`. ✓ in exact arithmetic.
- Rounding: `catchUp` is floored (L202) while the real catch-up is a difference of two floors, `⌊a⌋ − ⌊b⌋ ∈ {⌊a−b⌋, ⌊a−b⌋+1}`;
  `_principalWithin` floors `term·rate/SPY` in the denominator (P up to 1 wei high). Net: `totalDebt_after ≤ creditLimit + 2`, and
  `= creditLimit + 1` is realised (A-3).
- Health: `creditLimit ≤ Σactive·min(ltv,lt) ≤ Σtotal·lt = threshold` (activeAssets ≤ totalAssets because OZ's
  `shares·(A+1)/(S+1)` floors and `shares ≤ S`), so `debt ≤ limit ≤ threshold ⇒ healthiness ≥ 1e27` — unless `limit == threshold`
  and the 1-wei overshoot lands, which is exactly the `ltv == lt, buffer == 0` configuration (A-3 PoC).
- Split-invariance of `f(P)`: drawing `P1` then `P2` in the same block pays `[f(P1) − f(0)] + [f(P1+P2) − f(P1)] = f(P1+P2) − f(0)`
  because the second call sees `prior' = prior + P1` and `r'(m) = r(P1 + m)` (the `extra` term at IRM L233-238). Exact up to the
  per-call floors (≤ 2 wei, fuzz 2000 runs). It is *not* time-invariant: `prior` decays as the average absorbs it (P6, lead).

**Worked example** (`FixedCredit.t.sol::test_workedExample`, real stack: senior 1,000,000 + junior 50,000 WETH at $1, lt 0.8,
ltv 0.5, slopes base 5 % / slope0 5 % / slope1 10 % / kink 80 %, term-multiplier slope 0.5, underwriter rate 20 %, market
multiplier 1.5, 400,000 cUSD reserve deposit, 30-day term):
```
  creditLimit: 525000000000000000000000
  availableCredit(30d): 498854376549043382130057
  liq rate after minting the whole limit (pre-multiplier): 291780821917808219178082192   (29.18 %/yr incl. term multiplier 1.459)
  uw rate: 200000000000000000000000000
  premiumForBorrow.liq: 17945277535081932136297     (= 498854.38 · 30/365 · 29.18 % · 1.5 ⇒ 17945.28)
  premiumForBorrow.uw: 8200345915874685733644       (= 498854.38 · 30/365 · 20 % ⇒ 8200.35)
  debt[id]: 524999999999999999999998
  totalDebt: 524999999999999999999998
  slack = creditLimit - totalDebt: 2
  healthiness: 1600000000000000000000006095
  availableCredit(30d) after full draw: 1
```
The full draw lands 2 wei inside the limit (the two component floors), health 1.6 (= lt/ltv). A second same-block draw is
quoted at 1 wei: `limit − catchUp` after `prior = 525,000` cUSD.

**I32 verdict.** *Borrow succeeds and healthiness ≥ 1e27*: holds in all 2000 + 2000 + 2000 fuzz runs with `ltv < lt` (default
buffer 0.1). *totalDebt ≤ creditLimit*: **REFUTED by 1 wei** whenever prior unabsorbed credit exists (fuzz found it on run 154 and
run 527; deterministic replay below). *Borrow succeeds* is also refuted in the `ltv == lt, buffer == 0` configuration: 47 of 1456
scanned terms revert `Unhealthy` on `borrow(availableCredit(term))`. See A-3.

---

## 3. Stablecoin haircut curve `_convertToAssets` / `_convertToShares` (I36)

**Derivation** (L236-294). With `S = totalSupply`, `B = badDebt`, `R = S − B`, the payout for `x` shares is
`p(x) = R − retained(S−x)`, `retained(rem) = rem·S·R / (S·R + rem·B)`. Properties (proof, then fuzz):
- `p(0) = 0`, `p(S) = R`; `p'(x) = (SR)² / (SR + (S−x)B)²`, so `p'(0) = (R/S)²` (the "≈ (backing/totalSupply)²" in the NatSpec)
  rising to `p'(S) = 1`. `p` is convex ⇒ `p(x) ≤ x·R/S ≤ x`: **never above par, never above backing**.
- Haircut `x − p(x) = B − (S−x)²·B / (SR + (S−x)B) ≤ B`, equality only at `x = S`. So the curve alone never needs the cap at L324.
- Inverse (L267-287): `retained = R − value`, `rem = retained·SR / (SR − retained·B)`; the denominator is `≥ R² + B > 0` because
  `value ≥ 1 ⇒ retained ≤ R − 1`. `B == S` (allowed by `recognizeBadDebt*`) gives `R = 0`, `anchor = 0`: `_convertToAssets` returns 0
  through `remaining·B > 0` and `_convertToShares` returns `supply` via `value ≥ recognized`. No division by zero.
- Rounding: the reachable paths are `_convertToAssets(·, Floor)` (`convertToAssets`, `redeem`, `instantRedeem`, `maxWithdraw`) and
  `_convertToShares(·, Ceil)` (`_quoteWithdraw`, `unlockedSupply`); `_opposite` rounds the subtracted `retained`/`remaining` the
  other way, then the decimal scaling rounds in the caller's direction. `_convertToShares(·, Floor)` exists only behind the
  `convertToShares` view; `_convertToAssets(·, Ceil)` has no caller at all (both OZ previews are overridden).

**Results on the real `Stablecoin` proxy with a 6-decimal `MockERC20` underlying** (`StablecoinCurve6.t.sol`, 20,000 runs each,
S ∈ [1, 1e30] share-wei, B ∈ [0, S]):
```
[PASS] testFuzz_inverse_sharesToAssetsToShares   quoteWithdraw(convertToAssets(x)) <= x; convertToAssets(that) == convertToAssets(x) exactly;
                                                 share gap <= 1e12·(S/R)^2 + 1e12
[PASS] testFuzz_inverse_assetsToSharesToAssets   a-1 <= convertToAssets(quoteWithdraw(a)) <= a; <= par; <= backing
[PASS] testFuzz_quoteThenConvertNeverExceedsBalance   convertToAssets(quoteWithdraw(onHand)) <= onHand; convertToAssets(unlockedSupply()) <= balance
[PASS] testFuzz_depositInstantRedeem_neverProfits     deposit at par then instantRedeem(max) returns <= deposit; == deposit iff B == 0
[PASS] testFuzz_depositRequestClaim_neverProfits      deposit -> requestRedeem -> (bad debt may grow) -> redeem(id): <= deposit
[PASS] testFuzz_splitNeverBeatsSingle                 instantRedeem(cut) + instantRedeem(x-cut) <= convertToAssets(x) + 1 asset-wei
[PASS] testFuzz_onWithdrawAccounting                  paid <= Δbacking < paid + 1e12; cap binds ⇒ badDebt == 0
```
The 18-decimal case is the round-1/2 result (unchanged code path apart from `10**underlyingDecimals == 1e18`); the 6-decimal
harness exercises the scaling that round 1 could not.

Two statements in the plan needed correcting; both are precision facts, not defects:
1. "Inverse within 1 asset-wei (= 1e12 share-wei at 6 dec)". The share gap is one asset-wei **measured on the curve**, whose slope
   is `≥ (R/S)²`, so it is up to `1e12·(S/R)²`; the fuzzer's first counterexample had 29 % bad debt and a gap of 1,958,543,873,943
   share-wei. In asset units the pair is exact: `convertToAssets(quoteWithdraw(convertToAssets(x))) == convertToAssets(x)`.
2. "`_onWithdraw` badDebt reduction never pays more than pre-haircut". `reduced = min(B, x − ⌊paid⌋)`; the floor adds < 1e12
   share-wei of dust to the exact haircut, so the cap binds only when the exact haircut is within one asset-wei of *all* remaining
   bad debt (a near-full exit, or `B < 1e12`). Then `badDebt → 0` and the dust (< 1 USDC-wei) stays on hand as unrecognised
   reserve. Fuzz CEX: S = 3.589925524471791550e18, B = 12771640401338, x = 3.02e18: backing fell by paid + 72,997,920,840 share-wei
   (7.3e-8 USDC) and bad debt cleared. Nobody is paid more than the curve.

**Worked example** (S = 1,000,000 cUSD, B = 100,000, R = 900,000, USDC 6-dec):
```
  payout for 10,000 cUSD (USDC 6d): 8108108108          (8,108.108108; marginal rate (0.9)^2 = 0.81)
  payout for 500,000 cUSD: 426315789473                  (426,315.79; average 0.853)
  payout for 1,000,000 cUSD: 900000000000                (900,000 = R)
  shares to withdraw 8,100 USDC (ceil): 9990009990009990009991
  shares to withdraw 1 USDC-wei (ceil): 1234567901235   (= 1e12 / 0.81, rounded up)
  payout for 1e12 share-wei (1 USDC-wei at par): 0      (0.81 asset-wei floors to 0)
  payout for 1.24e12 share-wei: 1
  payout for 1.2346e12 share-wei: 1
  ceil-inverse of that payout (share-wei): 1234567901235
```

---

## 4. Floating index — `_growIndex`, `_borrowWithin`/`_repayWithin`, `_premium`

**`_growIndex` (L195-202).** `local' = local · (globalNow/lastGlobal)^m`, with `rayDiv` half-up, `rayPowRay`, `rayMul` half-up.
For `m = 1e27` the code path is `exp == RAY ⇒ return base` (no transcendental at all); for `m = 2e27` it is one `rayMul(base, base)`;
only a **fractional** multiplier reaches `rayLn`/`rayExp`. The base is `≥ RAY` whenever `globalNow > lastGlobal` (halmos
`check_rayDiv_geRay`), so I28 applies.

**I29 (differential, Python, `growindex_split.csv`).** One step vs `n` steps over the same interval, local index from `RAY`,
integer global path `G_i = round(G_0·(1+g)^{i/n})`. `d = split − one` in wei of a 1e27-scaled index (rel = d/one):

| mult | growth | n=1 | n=100 | n=8760 | n=30000 | exact |
|---|---|---|---|---|---|---|
| 1.0 | 10 % | 0 | +1 | −18 | −33 | 1.1000…5123 |
| 1.0 | 50 % | 0 | −9 | −46 | −642 | 1.5 |
| 1.5 | 10 % | 0 | −577 | −32757 | −24340 | 1.15368973298716671042368685257 |
| 1.5 | 50 % | 0 | −1211 | −48551 | −210912 | 1.83711730708738357364796305603 |
| 2.0 | 10 % | 0 | +41 | +822 | +9340 | 1.21 |
| 2.0 | 50 % | 0 | +79 | −9286 | +10497 | 2.25 |
| 1.25 | 50 % | 0 | −607 | −27331 | −190775 | 1.66002287955048238861318541016 |
| 1.999 | 50 % | 0 | −1856 | −82962 | −439825 | 2.24908788843396007261823906427 |

Over the full grid (5 multipliers × 5 growths × 7 splits): `split < one` 110, `split > one` 24 (all on the integer paths m = 1.0
and 2.0, where only half-up `rayMul`/`rayDiv` act), equal 41. **Directional statement:** with a fractional multiplier, splitting
never accrues more (0 cases) and accrues less by at most 14.6 wei per step (worst single-step error measured: 14.3 wei over 50,000
random steps; realistic 12-second steps at 10 %/yr drift −1.3 (m = 1.25), −2.3 (m = 1.5), −3.0 (m = 1.75) wei per step). With an
integer multiplier the error is two-sided half-up and bounded by ±1 wei per step. Worst observed relative deviation: 2e-22 after
30,000 steps at 1.999× and 50 % growth — on a 1e12-cUSD market that is 2e-10 cUSD per year. The `forge` counterpart
`testFuzz_growIndex_splitNeverGainsMuch` (100,000 runs, n ≤ 32) bounds the split at `one + 4n` wei above and `one − 40n` below.
**I29 holds: floor-dominated, direction "more splits accrue less", bound ≈ 15 wei/step (≤ 3 wei/step realistic).**

**I31 (`_borrowWithin` L148-154, `_repayWithin` L159-167).** Proof: `newScaled = ⌊(current+req)·RAY/idx⌋ ⇒ newScaled·idx/RAY ≤
current + req ⇒ minted = round(newScaled·idx/RAY) − current ≤ req`; and `newScaled·idx/RAY > current + req − idx/RAY ⇒
minted > req − idx/RAY − 0.5`, so `shortfall < idx/RAY + 0.5 ≤ ⌊idx/RAY⌋ + 1`. No underflow at L152: `current ≤ s·idx/RAY + 0.5`
gives `(current + req)·RAY/idx ≥ s` for `req ≥ 1`, so `newScaled ≥ s` and the half-up product is monotone. Mirror for repay with
ceil. **Liveness:** `minted ≥ 1` needs `req > idx/RAY + 0.5`, i.e. `req ≥ ⌊idx/RAY⌋ + 2` — the "+1" in the plan is not enough,
which the fuzzer found on run 45,840:
```
[FAIL: liveness: 0 <= 0; ... args=[31536000, 693147180559945309417232121, 1000]] testFuzz_borrowWithin_bounds  (before the threshold fix)
   bound ⇒ idx = 999693147180559945309417232122 (999.69 ray), scaled = 31536000, requested = 1000 = ⌊idx/RAY⌋+1 ⇒ minted = 0
[FAIL: liveness: 0 <= 0; ... args=[2439649223, 1000000000000000000000000000000000, 1000]] testFuzz_repayWithin_bounds
   bound ⇒ idx = 999999999999999999999999999000, scaled = 2439649223, debt = 2439649223000, requested = 1000 ⇒ burned = 0
```
With the threshold at `⌊idx/RAY⌋ + 2` all bounds pass 100,000 runs (`forge_A_floating.log`). Shortfall ≤ ⌊idx/RAY⌋ + 1 holds.

**Liveness corollary — concrete state (A-2, PoC `test_liquidationRevertsOnDustDebt_realMarket`).** `liquidate` calls
`_repayWithin(debt, min(amount, maxLiquidatable()))` before `_liquidate`; if that rounds to `burned == 0` it reverts
`InvalidScaledAmount` for *every* `amount`. That needs `maxLiquidatable() < ⌊idx/RAY⌋ + 2` with `maxLiquidatable() < debt`, i.e. a
market whose whole debt is a handful of wei. Real-stack state (senior tranche 1011 wei WETH at $0.0109 ⇒ `totalCapital = 11`,
`lastLiquidityIndex = 10e27`, `scaledDebt = 1` via `vm.store`, both reachable: any `repay` leaving `< idx/RAY` wei rounds the scaled
debt up to 1):
```
  totalDebt = 10, debtLiquidationThreshold = rayMul(11, 0.8e27) = 9, healthiness = 0.9e27 (unhealthy)
  maxLiquidatable: 9   (= rayDiv(rayMul(1.25e27,10) - 9, 1.25e27 - rayMul(1.02e27, 0.8e27)) = rayDiv(4, 0.434e27) = 9; cap min(10, 11) = 10)
  unrecoverableDebt = 0 (recoverable = rayDiv(11, 1.02e27) = 11)
  liquidate(recipient, max)  -> revert InvalidScaledAmount   (newScaled = ceil(1·RAY/10e27) = 1; burned = 10 - rayMul(1, 10e27) = 0)
  liquidate(recipient, 9)    -> revert InvalidScaledAmount
  liquidate(recipient, 1)    -> revert InvalidScaledAmount
  repay(max) from anyone     -> repaid 10, totalDebt 0     (requested >= debt bypasses the rounding branch)
```
`writeOff()` has the same shape (`_repayWithin(debt, unrecoverableDebt())`) and reverts when `0 < unrecoverableDebt() <
⌊idx/RAY⌋ + 2`. A barely-unhealthy market of *normal* size cannot hit this: `maxLiquidatable ≈ 0.58·debt` at the boundary, so
`burned == 0` needs `debt < 2·(⌊idx/RAY⌋+2)` wei. Dust-only; the market stays flagged unhealthy (`_setTranches`, fixed `extend`
revert `Unhealthy`) until anyone repays the dust. Informational.

**`_premium` (L215-227) — telescoping and underflow.** `liq + uw = s·rayMul(L1,U1)·… − s·rayMul(L0,U0)·…` exactly by construction
(the two subtractions share the middle term), and both differences are non-negative iff `L1 ≥ L0` and `U1 ≥ U0`, because
`rayMul(a, b)` is monotone in `a` and `rayMul(a, f ≥ RAY) ≥ a` (halmos `check_rayMul_geRay_noShrink`, `check_rayMul_monotone`).
So the question is monotonicity of the two indices:
- `L1 = _growIndex(L0, …) = rayMul(L0, rayPowRay(base ≥ RAY, m)) ≥ L0` by I28 (`rayPowRay ≥ RAY`) and the lemma. ✓
- `U = IRM.underwriterIndex(market) = _index(underwriterData[market])` (L311-317): `stored (or 1e27) · compounded(rate, lastUpdate→now)`
  with `compounded ≥ RAY` and increasing in elapsed (every term of the cubic is non-negative and non-decreasing in `exp`). The only
  writer is `updateUnderwriterRate` (L124-131), which stores `underwriterIndex(market)` evaluated *now* — i.e. ≥ any value read earlier
  — and restarts the clock. A rate of 0 freezes the index; nothing lowers it. A fresh market has `index == 0, lastUpdate == 0,
  rate == 0` ⇒ `compounded(0, 0→now) = RAY` ⇒ `1e27`, matching `FloatingMarket.initialize`. **Monotone: proof + fuzz 100,000 runs on
  the real IRM** (`testFuzz_underwriterIndexMonotone`, random rates in `[0, 1e27]`, random warps, rate to zero then a year).
- `_premium` therefore cannot underflow (fuzz 100,000: `testFuzz_premium_telescopes`; halmos `check_premium_telescopes`, §6). If the
  underwriter index *could* decrease (e.g. a future setter), L226 panics 0x11 — `test_premium_underflowsIfUnderwriterIndexDecreases`
  demonstrates the panic with a 10 % drop, documenting the dependency.

The round-1 Low ("`totalDebt` drifts above `creditBackedSupply`; full repay reverts") is **closed by construction** in this commit:
`_premium` mints exactly the getter's rise, `_borrowWithin`/`_repayWithin` mint/burn exactly the getter's move, and `liquidate`
re-reads `maxLiquidatable()` on identical state so `repaid == cleared`. `testFuzz_debtEqualsCreditBacked` (100,000 runs) ends every
random sequence with `repay(max) == totalDebt()` and `totalDebt() == 0`. The global Σ identity is the lead's I30 handler.

---

## 5. Transcendental functions — `rayPow`, `rayLn`, `rayExp`, `rayPowRay` (P5, I28)

`audit/v3/models/wadray_check.py` ports the four functions statement-by-statement (half-up `rayMul`/`rayDiv`, exact 512-bit
`mulDiv` = Python `//`, floor `x /= 2`, `term / n`, unchecked `<<`) and diffs them against mpmath at 80 digits. 1,000,000 random
points per primary suite plus the requested boundaries; seed 20260914; full log in `output/wadray_check.txt` (182 s).

**`rayLn(x)`** — artanh series on `x ∈ [RAY, 2RAY)` after `k` halvings, `ln = 2·Σ + k·LN2_RAY`.
```
  [rayLn, x log-uniform in [RAY, 1e40]] n=1000019
    max abs err   = 88.815368 wei  at 2^256-1        signed range = [-88.8, 0.0] wei (impl - exact)
    impl > exact (>0.5 wei): 0   impl < exact: 1000016   |d|<=0.5: 3      => one-sided LOW
  [rayLn, x = RAY + z, z log-uniform in [1, 1e26]] n=250000
    max abs err   = 14.15344 wei                     signed range = [-14.15, 0.47] wei      => one-sided LOW
  loop stats: max k (halvings) = 166, max series iterations = 26, max n reached = 53
  x = 2^256-1: k = 166 halvings, series iterations = 13 (bounded, no DoS)
  early-exit check: 0 mismatches between break/no-break variants over 200k+boundary points (exit is lossless)
  monotonicity around x = 2*RAY: 2RAY-1 -> ...232098, 2RAY -> ...232121, 2RAY+1 -> ...232121; violations: []
  random adjacent monotonicity (x, x+d): 0 violations
```
Boundaries: `rayLn(RAY+1) = 0` (exact 1.0), `rayLn(RAY+2) = 0` (exact 2.0), `rayLn(RAY+4) = 2` (exact 4.0) — the floor of
`v = z·RAY/(2RAY+z)` loses < 1 wei, doubled by `2·sum`; `rayLn(2RAY−1) = LN2_RAY − 23`, `rayLn(2RAY) = LN2_RAY` (−0.46 wei),
`rayLn(1e30) = …4331` (−33 wei), `rayLn(1e40)` −32 wei. The "max rel err = 1.0" in the log is this 1-wei absolute error at `RAY+1`
where the exact value is 1 wei; away from `x ≈ RAY` the relative error is ≤ 5e-27. **Early exit `if (term < n) break` (L145) is
lossless:** `term_{n+2} = rayMul(term_n, v2) ≤ term_n` for `v2 < RAY`, so once `term_n < n` every later `term/n'` is 0 — confirmed by a
no-break variant over 200k points. `k` is bounded by 166 (`x = 2^256−1`); the reachable `x` (§ below) gives `k ≤ 76`.

**`rayExp(x)`** — Taylor series on `r = x mod LN2_RAY`, then `<< k`.
```
  [rayExp, x uniform in [0, LN2)  (k = 0, the only band reachable with base < 2)] n=1000000
    max rel err = 1.0967e-26   max abs err = 18.255652 wei   signed range = [-18.26, 0.0]  => one-sided LOW
  [rayExp, x uniform in [0, 53e27]  (k up to 76, the reachable bound)] n=250000
    max rel err = 3.26017e-26   impl > exact: 202307   impl < exact: 47692   => two-sided
  [rayExp, x uniform in [0, 115e27]] n=250016   max rel err = 7.31074e-26   => two-sided
  loop stats: max series iterations = 24, max n reached = 24 (of the 47 allowed), max k = 165
```
For `k = 0` the series floors make it one-sided low (≤ 18.3 wei). For `k ≥ 1` the truncated constant `LN2_RAY =
0.693147180559945309417232121` (true …121458…) makes `r` too large by `4.58e-28·k`, so the result **over**-estimates by up to
`k·4.6e-28` relative — 3.3e-26 at k = 76. Two-sided but ≤ 1e-25.

**`exp <<= k` overflow (L166).** Shifts are unchecked in Solidity. Bit-exact bisection:
```
  smallest x with (exp << k) >= 2^256: x = 115275880712506765742325653747 (= 115.275880713 real), k = 166, unshifted exp = 1237940039285380274899124224
    rayExp(115275880712506765742325653747) wraps to 0        (true value ~ 1.1579209e+77)
    rayExp(115275880712506765742325653746) = 115792089237316195423570984915151803064092197900604734745615470749933446889472 (no wrap)
```
**Reachability from `_growIndex`:** the argument is `rayMul(frac, rayLn(base))` with `frac < RAY` and
`base = rayDiv(globalNow, lastGlobal)`. `rayDiv` reverts unless `globalNow ≤ (2^256 − b/2)/RAY ≈ 1.158e50`, and `lastGlobal ≥ RAY`,
so `base ≤ 1.158e50` and `rayLn(base) ≤ 53,106,083,201,667,532,273,839,884,492` (53.106 real) — less than half the wrap threshold.
Hence `k ≤ 76` and the wrap is **unreachable** from the only consumer; the global index would have to grow by 1.2e23× between two
charges of one market and the rayDiv guard reverts first. With a multiplier `≥ 2e27` the integer part `rayMul(base, base)` reverts
even earlier, at `base > 3.4e38` (growth > 3.4e11×). Reverts, never silent wrap. A `require(k < 166)` would cost ~20 gas and make the
library safe for any future caller (A-6).

**`rayPowRay(base, exp)`**
```
  [rayPowRay, base=RAY+z (z log-uniform [1,1e27]), exp uniform [0, 2e27]] n=1000000
    max rel err = 3.78002e-26  max abs err = 149.28945 wei  at (1991153960953414191973138432, 1994401060212664525075801831)
    signed range = [-149.29, 0.91] wei    impl > exact (>0.5 wei): 565   impl < exact: 761639   |d|<=0.5: 237796   => two-sided (over by < 1 wei only)
  [rayPowRay, base log-uniform [RAY, 1e30], exp uniform [0, 2e27]] n=250000
    max rel err = 4.0168e-26   signed range = [-32026601.0, 0.0] wei   => one-sided LOW
  [rayPowRay, base=RAY+z (z log-uniform [1,1e24]), exp=1.5e27  (realistic band)] n=250000
    max rel err = 7.42804e-27  max abs err = 7.436541 wei   signed range = [-7.44, 0.12]   => one-sided LOW
  [rayPow, a log-uniform [RAY, 1e28], n in [1, 4]] n=250000
    max rel err = 1.37842e-27  signed range = [-98.28, 98.71] wei   => two-sided (half-up)
  I28 violations (result < RAY, or exp>=RAY and result < base): 0
  monotonicity in base (b, b+d): 0 violations     monotonicity in exp (e, e+d): 0 violations
```
The 0.91-wei over-estimates are the final half-up `rayMul(c, …)`; no result exceeds the exact value by ≥ 1 wei anywhere. The
**seam at `exp == RAY`** (`return base`) vs `RAY − 1` (through ln/exp) is monotone but jumps by up to the accumulated ln/exp loss:
`base = 2RAY: f(RAY−1) = 1999999999999999999999999985, f(RAY) = 2e27, f(RAY+1) = …002`; `base = 1e28: f(RAY−1) = …9800, f(RAY) = 1e28,
f(RAY+1) = …0020` (exact `…9977`). A market at multiplier `1e27 − 1` accrues ~23 wei less per 2× of growth than at `1e27` — not
observable in cUSD.

**I28 proof (structural, holds without tolerance).** For `b ≥ RAY`: `rayPow(b, n)` is a product of `rayMul` by factors `≥ RAY`
starting from `RAY`, and `rayMul(a, f ≥ RAY) = ⌊(a·f + H)/RAY⌋ ≥ ⌊(a·RAY + H)/RAY⌋ = a` (halmos `check_rayMul_geRay_noShrink`); so
`rayPow(b, n) ≥ RAY`, and `≥ b` for `n ≥ 1` since `rayPow(b, 1) = rayMul(RAY, b) = b` exactly. `rayExp(x) ≥ RAY` for all `x` (starts
at `RAY`, adds non-negative terms, shifts left). `rayPowRay` returns `rayMul(c, rayExp(·)) ≥ c` by the same lemma. Hence
`rayPowRay(b ≥ RAY, e) ≥ RAY`, and `≥ b` when `e ≥ RAY` (then `integer ≥ 1`). Confirmed at 1.25e6 random points + boundaries
(Python) and 100,000 runs on the real library (`testFuzz_rayPowRay_I28`). **P5 REFUTED**: the floating index never falls and the
under-accrual is ≤ 1.5e-25 relative per step.

---

## 6. halmos

Environment: halmos 0.3.3 (venv), solvers available: yices (bundled), z3 4.12.6 (python). Harness: `audit/v3/tests/scratch/A/HalmosMath.t.sol`
(12 `check_` functions: `rayMul`/`rayDiv` half-up bounds, monotonicity, `≥ RAY` lemmas; `_borrowWithin`/`_repayWithin` bounds and
liveness; `_premium` telescoping; the 6-dec curve inverse and below-par). Every command and result verbatim (`output/halmos_A.log`,
`output/halmos_A2.log`):

HALMOS_PLACEHOLDER

---

## 7. MathUtils binomial and PremiumVesting floors

**`calculateCompoundedInterest` vs `e^{rt}`** (Python, `mathutils_cubic.csv`; shortfall = 1 − cubic/exact):

| rate | 1 day | 30 days | 1 year | 5 years |
|---|---|---|---|---|
| 5 % | 2.1e-13 | 2.9e-9 | 5.2e-6 | 6.3e-4 |
| 50 % | 1.1e-11 | 1.2e-7 | 1.8e-3 | **24.2 %** |
| 100 % | 4.6e-11 | 1.8e-6 | **1.90 %** | **73.5 %** |
| 500 % | 2.5e-9 | 8.6e-4 | **73.5 %** | ≈100 % (2.9e30 vs 7.2e37) |

Direction: every Taylor term is positive and the cubic truncates after the third and floors five times, so `cubic ≤ (1+x)^n ≤ e^{nx}`
**always** — borrowers are under-charged, premium recipients (cUSD stakers for the liquidity leg, tranche/underwriter depositors for
the underwriter leg) are under-paid. It depends only on `r·t` for a single un-checkpointed interval: 1.9 % at `rt = 1`, 14 % at
`rt = 2`, 73 % at `rt = 5`. Aave keeps `t` short by checkpointing on every reserve interaction; Cap's **liquidity** index is
checkpointed on every stablecoin mint/burn/deposit/withdraw (`_updateLiquidityRate`, IRM L242-248), but the **underwriter** index
is checkpointed only by `updateUnderwriterRate` (L124-131), i.e. by a market-owner action. The marginal (daily) accrual a market's
borrower is charged, `t` years after the last rate update:
```
    rate=0.20 t=1y: daily increment cubic/exact = 0.998899     t=2y: 0.992816     t=5y: 0.93741
    rate=1.00 t=1y: daily increment cubic/exact = 0.937241     t=2y: 0.789038     t=5y: 0.469903
```
See A-1. Fixed markets are unaffected (simple interest `chargeableDebt·term·rate/SPY`, no compounding by design).

**PremiumVesting floors** (`VestingAndIrmDust.t.sol`, real Tranche on the deployed stack):
```
[PASS] test_vestingDustStrandedUnderContinuousPoking
  pot: 1000000000000000000000
  remaining after 2000 x 12s pokes: 573749731434253605349
  expected continuous remaining (1e21 * e^-(24000/43200)): 573753000000000000000
  remaining after a further 40 days: 0
  claimed by the only staker: 999999999999999999999
  stranded in contract balance (per-share floor dust): 1
[PASS] testFuzz_vestingSplitNeverGains (runs: 20000)     ca + cb <= single + 1 for any split of a balance
```
- Max dust stranded per accrual: `_vested` (L315) floors `remainder·w/RAY`; at 12-second pokes `w ≈ 2.78e-4·RAY`, so a remainder
  below ~3,600 wei does not move that call. It is *not* lost: `_weight` reaches `RAY` once `rayPow(retention, elapsed) == 0`, which
  the model puts at 2,715,648 s (31.4 days) of no accrual; the test shows the remainder at exactly 0 after 40 idle days. The per-share
  floor (L242) strands `< supply/RAY` wei per accrual in the contract balance — 1 wei total after 2000 accruals on a 1e21 pot
  (`< 1000e18/1e27 = 1e-6` wei per accrual, accumulated). Over the IRM's `retentionPerSecond` the same `rayPow` decays to exactly 0
  after 2.6 days (1 h period) / 62.9 days (1 day period), so `_averagingWeight` saturates at `RAY` — intended.
- The 573,749.73 vs 573,753.00 gap is the discrete definition `(1 − 1/T)^t` vs `e^{−t/T}` (`e^{−t/(2T²)} = 0.9999936` at t = 24000 s),
  not rounding.
- Farmable? No. Every floor is against the claimant (`_owed`, `_vested`, per-share); splitting a balance over accounts or claiming
  every block only forfeits more (fuzz 20,000). There is no ceil anywhere in the vesting path.

**IRM average order / `kink == 1e27`.** `_carry` (L279-283) preserves `credit ≤ supply` when both the stored averages and the
observations are ordered (proof: `round(a+d) − round(a) ≤ ⌊d⌋ + 1 ≤ s − c` for `d = (s−c)·w/RAY < s − c` unless `w = RAY`, when it
is exact; fuzz 20,000 `testFuzz_carryPreservesOrder`), so `averageUtilizationAfterMint ≤ 1e27` and `_nextLiquidityRate` never
divides by `1e27 − kink == 0` (fuzz 20,000 `testFuzz_kinkAtOne_noRevert` on the real IRM with kink pinned at 1e27). The one way to
break the precondition is `creditBackedSupply > totalSupply`, which needs `recognizeBadDebtInReserve` to push `C + B > S` (it
checks only `B ≤ S`) followed by `coverBadDebt` burning more than `S − C`; then `utilizationRate()` exceeds `1e27` and, with
`kink == 1e27`, every stablecoin mint/burn/deposit/withdraw reverts in `_updateLiquidityRate`. That is I35's domain (lead/WS-E); noted
here as the arithmetic consequence.

---

## 8. Diff against Aave v3 core (`protocol/libraries/math/`)

From knowledge of `aave-v3-core` (v1.19.x, `WadRayMath.sol` and `MathUtils.sol`, BUSL-1.1, `pragma ^0.8.0`), not a file diff —
the repository has no Aave dependency (`node_modules` has none) and the brief allows a from-memory comparison.

`WadRayMath.sol` L1-79 (`WAD`, `HALF_WAD`, `RAY`, `HALF_RAY`, `WAD_RAY_RATIO`, `wadMul`, `wadDiv`, `rayMul`, `rayDiv`) and
L169-192 (`rayToWad`, `wadToRay`) are **assembly-identical** to Aave v3, including the overflow guards
`iszero(or(iszero(b), iszero(gt(a, div(sub(not(0), HALF_RAY), b)))))` and the `div(b, 2)` half-up in the divisions, and the
library-level NatSpec "Operations are rounded. If a value is >=.5, will be rounded up". Divergences:
- `pragma solidity 0.8.36` (Aave `^0.8.0`); author tag "Cap Labs & Aave"; NatSpec reflowed to `///`.
- Added by Cap: `LN2_RAY` (L23), `rayPow` (L81-105), `rayPowRay` (L107-123), `rayLn` (L125-149), `rayExp` (L151-167). Aave has no
  integer-power, ln or exp helper; these are the in-scope Cap code covered in §5.

`MathUtils.sol`: `SECONDS_PER_YEAR = 365 days`, `calculateLinearInterest`, both `calculateCompoundedInterest` overloads are
**logic-identical** to Aave v3 (`exp = current − last`, `expMinusTwo = exp > 2 ? exp − 2 : 0`, `basePowerTwo = rate.rayMul(rate) /
(SPY*SPY)`, `basePowerThree = basePowerTwo.rayMul(rate) / SPY`, `secondTerm = exp·(exp−1)·basePowerTwo / 2`, `thirdTerm =
exp·(exp−1)·(exp−2)·basePowerThree / 6`, `RAY + rate·exp/SPY + secondTerm + thirdTerm`, with the same `unchecked` placement).
Divergences: parameter types `uint256 lastUpdateTimestamp` (Aave `uint40`); return variables named; `//solium-disable-next-line`
comments kept. No arithmetic divergence. Aave's known caveats carry over: the cubic under-accrues (§7) and is only accurate when the
interval is re-checkpointed frequently — which Aave guarantees and Cap does not for the underwriter index (A-1).

---

## Findings

### [LOW] A-1 Underwriter index is a single-checkpoint cubic: underwriters are under-paid without bound in time since the last `updateUnderwriterRate`
**Location:** contracts/cap/InterestRateModel.sol:L124-L131 (`updateUnderwriterRate`), L311-L317 (`_index`); contracts/utils/MathUtils.sol:L43-L78 (`calculateCompoundedInterest`); contracts/cap/market/FloatingMarket.sol:L130-L136 (`premiumIndices`), L215-L227 (`_premium`)
**Impact:** The underwriter premium a floating borrower pays over `[t1, t2]` is `s·L·(U(t2) − U(t1))` with `U(t) = stored ·
cubic(rate, t − lastUpdate)`. `cubic` is the Aave 3-term binomial, which is `≤ e^{rt}` always and diverges with `r·t`: after one
year at a 100 % rate (the deploy maximum `defaultMaximumUnderwriterRate = 1e27`) the daily accrual is 93.7 % of the nominal
compounded rate, after two years 78.9 %, after five 47.0 %; the cumulative index is 1.9 % / 14 % / 73 % short. At the 20 % default
rate it is 0.1 % after one year and 6.3 % (marginal) after five. The shortfall is borne by the tranche depositors whose collateral
backs the market (third parties), and by cUSD stakers for the liquidity leg between stablecoin interactions; borrowers keep the
difference. Nothing in the contracts re-checkpoints the underwriter index — the liquidity index is re-based on every stablecoin
mint/burn/deposit/withdraw (IRM L242-248), the underwriter index only when the market owner changes the rate.
**Likelihood:** No attacker; default behaviour of every floating market whose underwriter rate is left alone. The market owner is
the party that sets the rate and, under the trust model (§4 of the plan; P14), is often the borrower — they have no incentive to
call `setUnderwriterRate` and every incentive not to. Cost to cause: zero.
**Exploit path:** not an exploit; a drift. 1. Owner sets `setUnderwriterRate(1e27)` at deployment. 2. Borrower draws. 3. Two years
pass with `chargePremium()` called daily (permissionless; keeps tranches funded). 4. Tranches have received 86 % of `s·L·(e^{2} − 1)`
instead of 100 %; the 14 % is never charged.
**Proof:** `audit/v3/models/wadray_check.py` §5 (bit-exact port, output above and in `output/mathutils_cubic.csv`):
```
    1.00    365d       2666663803286307009891659072    2718281828459045271479606968.219083    0.0189892
    1.00   1825d      39332978898869386515698295360   148413159102576613281355704965.4762     0.734976
    rate=1.00 t=2y: daily increment cubic=0.0021647129 exact=0.0027434825 ratio=0.789038
```
**Recommendation:** Checkpoint the underwriter index on every charge: in `FloatingMarket._chargePremium` call
`IInterestRateModel(irm).updateUnderwriterRate(IInterestRateModel(irm).underwriterRate(address(this)))` (markets hold the MARKET
role the function is restricted to), or add an IRM `checkpointUnderwriter(market)` callable by the market. Each checkpoint restarts
the cubic from `t = 0`, which is exactly the regime it is accurate in (daily: 4.6e-11). Second-order: one extra SSTORE pair per
charge; `premiumIndices()` keeps working because `_index` is read-only; also document in the IRM NatSpec that `ratePerYear` is
approximated by the cubic between checkpoints.
**Invariant broken:** none of I28–I40; an accuracy property (accrual = `e^{rt}` to within the documented "slight" underpayment) that
the code implies but does not state.

### [INFORMATIONAL] A-2 `_repayWithin` rounds a few-wei liquidation or write-off to zero and reverts; a dust-debt market cannot be liquidated or written off
**Location:** contracts/cap/market/FloatingMarket.sol:L83-L96 (`liquidate`), L104-L113 (`writeOff`), L159-L167 (`_repayWithin`)
**Impact:** With `requested < ⌊index/RAY⌋ + 2` the ceil inverse can leave the scaled debt unchanged and L166 reverts
`InvalidScaledAmount` regardless of the liquidator's `amount` (it is clamped to `maxLiquidatable()` first). The state is reachable
only when the whole debt is a few wei (`maxLiquidatable ≈ 0.58·debt` at the health boundary), so the money at stake is wei; the
consequence is a market flagged unhealthy that no liquidator or guardian can clear, blocking `setTranches`/`setTrancheWeights`
(`Unhealthy`) until anyone repays the dust — which `repay(≥ debt)` always can, because `requested ≥ debt` bypasses the rounding.
**Likelihood:** any `repay` that leaves `< index/RAY` wei rounds the scaled debt up to 1 (debt = `index/RAY` wei); then withdraw
collateral down to the ceil-locked minimum and let the price move. Costs the borrower nothing; gains them nothing.
**Exploit path:** see §4 concrete state.
**Proof:** `FloatingRounding.t.sol::test_liquidationRevertsOnDustDebt_realMarket` (passes, i.e. reproduces the reverts on the real
market), output in §4. Liveness threshold `⌊idx/RAY⌋ + 2` from the fuzz counterexamples in §4 (100,000 runs after the fix).
**Recommendation:** In `_repayWithin`, when `burned == 0` and `requested > 0`, fall back to `newScaled − 1` (burn one scaled unit,
i.e. `burned ≤ idx/RAY + 1` wei, still `≤ requested + idx/RAY`), or let `liquidate`/`writeOff` treat `burned == 0` as a no-op instead
of reverting. Second-order: the fallback can burn up to `idx/RAY` wei more than requested; bound it by `requested` as the existing
code does for the ceil and document the ±1-scaled-unit granularity.
**Invariant broken:** I31 liveness corollary (documented); I26 not affected.

### [INFORMATIONAL] A-3 `availableCredit(term)` over-quotes by one wei: I32 (`totalDebt ≤ creditLimit`) is refuted, and with `ltv == lt, buffer == 0` the quoted maximum borrow reverts `Unhealthy`
**Location:** contracts/cap/market/FixedMarket.sol:L186-L208 (`availableCredit`), L294-L296 (`_principalWithin`), L337-L351 (`_borrowPremium`), L230-L248 (`_borrow`)
**Impact:** `catchUp` (L202) is a single floor of the ideal catch-up, while the premium actually charged is a difference of two
floored premiums per component (L344-350) and `_principalWithin` floors `term·rate/SPY` in its denominator; together the debt after
a full draw can be `creditLimit + 1`. Effects: (a) the NatSpec claim "the debt lands inside the limit" and plan invariant I32 fail by
1 wei — `availableCredit()` then reads 0, nothing else changes; (b) when `creditLimit == debtLiquidationThreshold` (`ltv == lt` and
`buffer == 0`, both accepted by `setLtv`/`setBuffer`) the health assert at L246 fails and `borrow(availableCredit(term), term)`
reverts `Unhealthy` while `borrow(availableCredit(term) − 1, term)` succeeds. No value moves.
**Likelihood:** any fixed market with unabsorbed same-window credit (`unsmoothedCredit() > 0`), i.e. after any recent borrow
anywhere in the protocol. Data-dependent: 47 of 1,456 scanned terms trigger the revert in the ltv == lt configuration; the fuzzer
found the 1-wei overshoot on runs 154 and 527 of 2,000 with the default `ltv < lt`.
**Exploit path:** none (a revert of the borrower's own transaction; 1 wei of limit).
**Proof:** `FixedCredit.t.sol::test_I32_overshootByOneWei` and `::test_I32_overshootRevertsAtLtvEqualsLt` (both pass, i.e. reproduce):
```
  term: 31462348
  prior unabsorbed credit: 159906471325799112499069
  creditLimit: 525000000000000000000000
  totalDebt before: 159906471325799112499069
  availableCredit(term): 228316919038471177059727
  quoted liq premium: 91219872185982085120157
  quoted uw premium: 45556737449747625321048
  principal + quoted premium + debt before: 525000000000000000000001
  totalDebt after: 525000000000000000000001

  terms scanned: 1456
  terms where borrow(availableCredit(term)) reverts Unhealthy: 47
  first such term (s): 388814
```
Original fuzz failure (before the assertion was relaxed to `limit + 2`):
```
[FAIL: totalDebt > creditLimit: 525000000000000000000001 > 525000000000000000000000; counterexample: ... args=[50000000000000000000000, 50000000000000000000000, 1000000000000000000000000, 1751]] testFuzz_I32_principalWithinCredit (runs: 154)
[FAIL: full draw overshoots creditLimit: 525000000000000000000001 > 525000000000000000000000; ... args=[12747, 100000000000000000000000, 0]] testFuzz_I32_fullDraw (runs: 527)
```
**Recommendation:** Round the sizing against the borrower: compute `catchUp` with `Math.mulDiv(..., Ceil)` (or `+ 2`), and use
`Math.mulDiv(term, rate, SECONDS_PER_YEAR, Ceil)` in `_principalWithin`'s denominator. Then `P + premium ≤ limit` holds for every
rounding path (each component of the real charge is at most `⌊ideal⌋ + 1`, covered by the two ceils). Second-order: quotes drop by
≤ 2 wei. Alternatively (cheaper) subtract 2 wei from `credit` at the end of `availableCredit`.
**Invariant broken:** I32 (by 1 wei; health clause only under `ltv == lt`).

### [INFORMATIONAL] A-4 Half-up rounding where a floor/ceil was required: `debtLiquidationThreshold`, `healthiness`, `variableCreditLimit`, `recoverableDebt` round in the borrower's favour; `healthiness()` masks a 1-wei excess at ≥ 2e27 wei of debt
**Location:** contracts/cap/market/BaseMarket.sol:L226 (`debtLiquidationThreshold`), L233 (`healthiness`), L259 (`recoverableDebt`), L321 (`variableCreditLimit`), L250-L251 (`maxLiquidatable`), L362 (`_liquidate` toSlash)
**Impact:** Each is ≤ 0.5 wei (threshold, credit) or ≤ `debt/(2·RAY)` wei (healthiness) in the borrower's favour. Observable: with
`debt = threshold + 1` and `threshold ≥ 2e27` (2e9 cUSD), `healthiness()` returns exactly `1e27`, so `_liquidate` reverts `Healthy()`
while `maxLiquidatable() > 0` and `_setTranches`/fixed `_borrow` treat the market as healthy. The liquidator-side half-ups (`toSlash`,
`perCleared`) are ≤ 1 wei the other way. None is exploitable for value.
**Likelihood:** always present; visible only at the wei.
**Proof:** `FloatingRounding.t.sol::test_healthinessHalfUpMasksOneWei` (real market, capital 4e27 at $1, lt 0.8 ⇒ threshold 3.2e27,
debt 3.2e27 + 1): `healthiness() == 1e27`, `maxLiquidatable() > 0`, `liquidate` reverts `Healthy`.
**Recommendation:** `Math.mulDiv(totalCapital(), lt, RAY, Floor)` for the threshold and the credit limit, `Math.mulDiv(threshold,
RAY, debt, Floor)` for healthiness, `Ceil` for `_slashPerDebt().rayMul(lt)` and `Floor` for `recoverableDebt` — every consumer then
errs toward the protocol. Second-order: none beyond 1 wei.
**Invariant broken:** none; I38 direction note for WS-D.

### [INFORMATIONAL] A-5 Transcendental library precision and direction (P5, I28, I29 — confirmation)
**Location:** contracts/utils/WadRayMath.sol:L107-L167; contracts/cap/market/FloatingMarket.sol:L195-L202
**Impact:** none adverse. Summary of §5: `rayLn` one-sided low (≤ 88.8 wei at 2^256−1, ≤ 14.2 wei near RAY); `rayExp` one-sided low
for `k = 0` (≤ 18.3 wei) and two-sided ≤ 7.3e-26 relative for `k ≥ 1` (LN2_RAY truncation); `rayPowRay` never over by ≥ 1 wei, under by
≤ 149 wei (1.5e-25) on `[RAY, 2RAY) × [0, 2e27]` and ≤ 7.4 wei in the realistic band; monotone in both arguments over 5e5 adjacent
pairs; I28 structurally proven; `_growIndex` split error one-sided low ≤ 15 wei/step with fractional multipliers, ±1 wei/step with
integer ones. `rayLn`'s early exit is lossless; the halving loop is bounded by 166.
**Likelihood / Exploit path:** n/a.
**Proof:** Python 1e6 (`output/wadray_check.txt`), fuzz 100,000 (`testFuzz_rayPowRay_I28`, `testFuzz_growIndex_splitNeverGainsMuch`).
**Recommendation:** none required. If the team wants the fractional path to be exactly consistent with the integer path at `exp = RAY`,
compute the integer part with `rayPow` and the fractional part from `rayLn(base)` once, or accept the ≤ 23-wei seam.
**Invariant broken:** none (I28, I29 hold).

### [INFORMATIONAL] A-6 `rayExp`'s `exp <<= k` is an unchecked shift; wraps at `x ≥ 115.2758807e27`, unreachable from `_growIndex`
**Location:** contracts/utils/WadRayMath.sol:L166
**Impact:** `rayExp(115275880712506765742325653747)` returns 0 (true value 1.16e77); any future caller passing an exponent ≥ 115.28
(in ray) gets a silently wrapped result. From the only current consumer the argument is `< 53.11e27` (bounded by the `rayDiv`
overflow guard on the base), so `k ≤ 76` and the wrap cannot occur; larger growth reverts in `rayDiv` (or `rayMul(base, base)` for
`m ≥ 2e27`, at growth > 3.4e11×).
**Likelihood:** unreachable today.
**Proof:** Python bisection (§5), verbatim above.
**Recommendation:** `if (k >= 166) revert();` before the shift (or `require(exp <= type(uint256).max >> k)`), so the library is safe
for any caller.
**Invariant broken:** none.

### [INFORMATIONAL] A-7 Stablecoin haircut curve: I36 holds in asset units; the 1e12-share-wei statement is the par case; `_onWithdraw`'s cap only ever books < 1 asset-wei of dust
**Location:** contracts/cap/Stablecoin.sol:L236-L294, L320-L330
**Impact:** none adverse (see §3). Two consequences worth stating in NatSpec: a redemption that pays 0 asset-wei (any `x ≤ 1e12·(S/R)²`
share-wei at 6 decimals) still burns the shares and books the full burn as a bad-debt reduction; when that reduction exceeds the
remaining bad debt the cap zeroes `badDebt` and leaves the dust on hand as unrecognised reserve (< 1 USDC-wei per event). Depositors
after bad debt is recognised buy at par and exit on the curve — by design ("Always at par, even with bad debt").
**Proof:** fuzz 20,000 × 7 on the real proxy at 6 decimals (§3), worked example.
**Recommendation:** none required; optionally reject `instantRedeem`/`redeem` that would pay 0 assets for > 0 shares.
**Invariant broken:** none (I36 holds as corrected).

### [INFORMATIONAL] A-8 PremiumVesting and IRM floors are bounded and not farmable; `kink == 1e27` is safe only while I35 holds
**Location:** contracts/utils/PremiumVesting.sol:L232-L246, L311-L332; contracts/cap/InterestRateModel.sol:L279-L306
**Impact:** ≤ 1 wei per accrual stranded in the vesting contract; ≤ ~3,600 wei of a pot parked while it is poked every 12 s, fully
vested after 31.4 idle days; splitting balances or claiming often only loses (fuzz 20,000). `_carry` preserves `credit ≤ supply` so
`averageUtilizationAfterMint ≤ 1e27` and the `1e27 − kink` divisor is never 0 for `kink == 1e27` (fuzz 20,000 on the real IRM) — unless
`creditBackedSupply > totalSupply`, reachable only through `recognizeBadDebtInReserve` (checks `B ≤ S`, not `C + B ≤ S`) followed by
`coverBadDebt`; then with `kink == 1e27` every `_updateLiquidityRate` reverts and the stablecoin freezes. Cross-reference for I35.
**Proof:** §7 outputs.
**Recommendation:** in `recognizeBadDebtInReserve` require `creditBackedSupply + badDebt ≤ totalSupply` (I35 as a check), which also
removes the only path to `utilization > 1e27`.
**Invariant broken:** none by this workstream; I35 precondition noted.

---

## Appendix: gas & style
- `WadRayMath.rayLn` L143: loop bound `n < 64` is never reached (max `n` 53 at `x = 2RAY−1`); `n < 56` would be equivalent.
- `WadRayMath.rayExp` L161: `n < 48` never reached (max 24); 30 would do.
- `FixedMarket._premium` computes `cumulativeDebt.rayMul(rate) / SECONDS_PER_YEAR` twice; `Math.mulDiv(cumulativeDebt, rate, RAY * SECONDS_PER_YEAR)` is one division and one rounding.
- `BaseMarket.healthiness` could early-return `type(uint256).max`-style sentinel instead of `1e27` at zero debt; unchanged semantics.
- `Stablecoin._convertToAssets(·, Ceil)` and `_convertToShares(·, Floor)` are dead paths (no caller) — keep for the OZ override contract but note it.

## Invariants
- **I28** holds (proof + Python 1.25e6 + fuzz 100k). Tolerance not needed for the lower bounds; monotonicity holds exactly over 5e5 adjacent pairs.
- **I29** holds; direction: fractional multipliers ⇒ more splits accrue *less*, ≤ 15 wei/step (≤ 3 wei/step at 12-s cadence); integer multipliers two-sided ±1 wei/step.
- **I31** holds (shortfall ≤ ⌊idx/RAY⌋ + 1, fuzz 100k, halmos §6); liveness threshold corrected to `⌊idx/RAY⌋ + 2`; corollary state in A-2.
- **I32 broken** by 1 wei (A-3): `totalDebt ≤ creditLimit + 2` is the bound that holds; "borrow succeeds" fails only for `ltv == lt, buffer == 0`.
- **I36** holds in asset units at 6 and 18 decimals; share-unit statement corrected to `1e12·(S/R)²`; no round trip profits (fuzz 20k × 7).
- New, implied by the code: **I41** `underwriterIndex(m)` is nondecreasing in time and across `updateUnderwriterRate` (proof + fuzz 100k) — `_premium`'s non-underflow depends on it. **I42** `avgCredit ≤ avgSupply` after every `_carry` given `C ≤ S` (fuzz 20k). **I43** `Σ(liq, uw) == totalDebt_after − totalDebt_before` exactly per charge (fuzz 100k, halmos).
- Not affected: I30 (lead), I35 (precondition for A-8 noted), I38 direction note (A-4).

## Hypotheses
- **P5 — REFUTED.** `rayPowRay(b ≥ RAY, e) ≥ RAY` structurally, `≥ b` for `e ≥ RAY`; the index never falls and under-accrues by ≤ 1.5e-25 relative per step (Python 1e6, fuzz 100k). `_premium` cannot underflow because both indices are monotone (proof + fuzz 100k on the real IRM).
- **I32 (owned here) — REFUTED at the wei** (A-3); economically null.
- **Halmos (task 6)** — see §6 for what proved and what timed out; nothing in this file is labelled "verified" on fuzz evidence alone.
