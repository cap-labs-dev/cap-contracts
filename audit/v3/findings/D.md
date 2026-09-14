# Workstream D — Liquidations & oracles

> **Post-verification status (lead, 2026-09-14):** D-1 **Medium confirmed** (`verify/D-1.md`: staked precondition; `optOut` restores repay only); D-2 **demoted to Low** (`verify/D-2.md`); D-3 **demoted to Low** (`verify/D-3.md`: guardian remedy exists; keeper path never fully clears). Report IDs: R3-M1; D-2, D-3 under Low.


Target: `cap-network` @ `a843c1d`. PoCs: `audit/v3/tests/scratch/D/` (8 files, 35 tests; run with
`FOUNDRY_TEST=audit/v3/tests/scratch/D forge test -vv`). Exactly the three tests prefixed `test_FAIL_`
fail on current code; every other test passes and documents behaviour. Model:
`audit/v3/tests/scratch/D/models/profitability.py`.

Owned hypotheses: P9, P10, P11, P13; invariant I38; the profitability sweep; LIQUIDATOR liveness;
L2/oracle assumptions.

Files read end to end: `contracts/cap/market/{BaseMarket,FloatingMarket,FixedMarket}.sol`,
`contracts/cap/{Tranche,InterestRateModel,Stablecoin}.sol`, `contracts/cap/oracle/{Oracle,ChainlinkAdapter}.sol`,
`contracts/interfaces/{IChainlink,IOracle}.sol`, `contracts/utils/PremiumVesting.sol`, `test/shared/CapDeployer.sol`
(note: every mock feed there gets `FEED_STALENESS = 3650 days`, so nothing in `test/` ever exercises a stale
feed against a funded market — the whole of P11 is invisible to the shipped suite; flagged to WS-F).

---

## 0. Liquidation math (item 1) — derivation, worked example, closed item

From `BaseMarket.sol:L224-L267, L341-L346`:

| quantity | code | formula |
|---|---|---|
| `debtLiquidationThreshold` | L224 | `TC·lt` |
| `healthiness` `h` | L230 | `TC·lt / D` (`1e27` when `D == 0`) |
| `_slashPerDebt` | L343 | `1 + b` |
| `recoverableDebt` `R` | L258 | `TC / (1+b)` |
| `unrecoverableDebt` `U` | L263 | `max(0, D − TC/(1+b))` |
| `maxLiquidatable` `M` | L245 | `min( (T·D − TC·lt) / (T − (1+b)·lt), D, R )` when `D > TC·lt`, else 0 |

`M` is the repay `x` solving `TC' · lt / D' = T` with `D' = D − x`, `TC' = TC − x·(1+b)`: `(TC − x(1+b))·lt = T·(D − x)`
⇒ `x = (T·D − TC·lt)/(T − (1+b)·lt)`. Writing `D = TC·lt/h`:

- `M_formula / D = (T − h) / (T − (1+b)·lt)`, `R / D = h / ((1+b)·lt)`, and `M_formula ≥ R ⇔ M_formula ≥ D ⇔ h ≤ (1+b)·lt`.
- So the cap `min(D, R)` binds **exactly** when `h ≤ (1+b)·lt = 0.816` at deploy params, which is the same
  condition as `U > 0`. Below that health every liquidation drains every tranche (`repaid = TC/(1+b)`,
  `slashed = TC`) and leaves `U` for `writeOff`. Verified for the whole price sweep in
  `D1_LiquidationMath.t.sol::test_capBindsExactlyWhenUnrecoverable`.

Worked example at deploy params (lt 0.8, buffer 0.1, T 1.25, b 0.02), `test_workedExample_partialBand`:
TC = $1000, borrow 500 at ltv 0.5, price → 0.55 ⇒ TC = 550, `h = 0.88`, `R = 539.2 > M`.
`M = (625 − 440)/0.434 = 426.267…`; liquidator burns 426.267 cUSD, receives $434.793 of collateral, market lands
on `h = 1.25`:

```
[PASS] test_workedExample_partialBand()
  repaid          : 426.267281105990783410
  slashed (USD)   : 434.792626728110599077
  health after    : 1.250000000000000000006781250
```

**Closed (one line):** `perCleared = T − (1+b)·lt ≥ 1.25 − 1.1·1 = 0.15 > 0` for every value the setters accept
(`setTargetHealth ≥ 1.25e27` L108, `setLt ≤ 1e27` L91, `_setLiquidationBonus ≤ 0.1e27` IRM L181);
`test_perClearedPositiveAtExtremes` runs the corner and checks the setters refuse anything past it.

---

## 1. Profitability sweep (item 2)

Mechanics: the liquidator burns `repaid` cUSD at face (`_repay`, `BaseMarket.sol:L335-L339`) and receives
collateral tokens whose **oracle** value is `repaid·(1+b)` (`Tranche.slash`, `Tranche.sol:L71-L95`). Let `d` be
the oracle's overstatement of the collateral versus the market price (`P_oracle = P_market·(1+d)`) and `c` the
liquidator's cost per cUSD in USD. Margin per cUSD repaid: **`m = (1+b)/(1+d) − c`**. Health does not enter the
per-unit margin at all; it only sets the size `M` and whether the market is drained.

### Table 1 — size of the call and whether the recoverable cap binds (deploy params, b = 2 %)

| health | `M / D` | cap binds (drains all collateral) | left for `writeOff` per $1 of debt |
|---|---|---|---|
| 0.999 |  57.83 % | no | 0 |
| 0.950 |  69.12 % | no | 0 |
| 0.900 |  80.65 % | no | 0 |
| 0.850 |  92.17 % | no | 0 |
| 0.820 |  99.08 % | no | 0 |
| **0.816** | **100.00 %** | boundary (`M == R == D`) | 0 |
| 0.800 |  98.04 % | yes | 0.0196 |
| 0.750 |  91.91 % | yes | 0.0809 |
| 0.700 |  85.78 % | yes | 0.1422 |
| 0.600 |  73.53 % | yes | 0.2647 |
| 0.500 |  61.27 % | yes | 0.3873 |

Partial liquidation (lands on `T`) only in `h ∈ [0.816, 1)`; the first liquidation at `h = 0.999` already clears
58 % of the debt because `T = 1.25` is far above 1.

### Table 2 — margin per cUSD repaid, `m = (1+b)/(1+d) − c` (before gas and dust)

cUSD at $1.00:

| bonus \ oracle − market | −5.0 % | −2.0 % | −1.0 % | 0 | +0.5 % | +1.0 % | +2.0 % | +3.0 % | +5.0 % |
|---|---|---|---|---|---|---|---|---|---|
| b = 0 % | +5.26 | +2.04 | +1.01 | 0.00 | −0.50 | −0.99 | −1.96 | −2.91 | −4.76 |
| b = 1 % | +6.32 | +3.06 | +2.02 | +1.00 | +0.50 | 0.00 | −0.98 | −1.94 | −3.81 |
| **b = 2 %** | +7.37 | +4.08 | +3.03 | **+2.00** | +1.49 | +0.99 | **0.00** | −0.97 | −2.86 |
| b = 5 % | +10.53 | +7.14 | +6.06 | +5.00 | +4.48 | +3.96 | +2.94 | +1.94 | 0.00 |
| b = 10 % | +15.79 | +12.24 | +11.11 | +10.00 | +9.45 | +8.91 | +7.84 | +6.80 | +4.76 |

cUSD at $0.98: add +2.00 pp to every cell. cUSD at $0.95: add +5.00 pp. (Full tables in the model output.)

### Table 3 — break-even oracle overstatement `d* = (1+b)/c − 1`

| bonus | c = 1.00 | c = 0.98 | c = 0.95 |
|---|---|---|---|
| 0 % | 0.00 % | 2.04 % | 5.26 % |
| **2 %** | **2.00 %** | 4.08 % | 7.37 % |
| 5 % | 5.00 % | 7.14 % | 10.53 % |
| 10 % | 10.00 % | 12.24 % | 15.79 % |

Reading: at the deploy bonus of 2 % a liquidation is unprofitable whenever the oracle lags a falling market by
more than 2 % — which is exactly the situation during a crash (Chainlink deviation thresholds are 0.5 % for
ETH/USD on mainnet, 1–2 % for most L2 / long-tail feeds, plus heartbeat lag). cUSD trading below par *helps*
the liquidator (it buys cUSD cheap and burns it at face).

### Table 4 — dollars at deploy params, TC₀ = $1,000,000, D = $500,000

| price | TC | h | repaid | collateral received @oracle | liquidator gross | `writeOff` remainder |
|---|---|---|---|---|---|---|
| 0.65 | 650,000 | 1.040 | 0 | 0 | 0 | 0 |
| 0.62 | 620,000 | 0.992 | 297,235 | 303,180 | 5,945 | 0 |
| 0.60 | 600,000 | 0.960 | 334,101 | 340,783 | 6,682 | 0 |
| 0.55 | 550,000 | 0.880 | 426,267 | 434,793 | 8,525 | 0 |
| 0.51 | 510,000 | 0.816 | 500,000 | 510,000 | 10,000 | 0 |
| 0.50 | 500,000 | 0.800 | 490,196 | 500,000 | 9,804 | 9,804 |
| 0.45 | 450,000 | 0.720 | 441,176 | 450,000 | 8,824 | 58,824 |
| 0.30 | 300,000 | 0.480 | 294,118 | 300,000 | 5,882 | 205,882 |
| 0.10 | 100,000 | 0.160 | 98,039 | 100,000 | 1,961 | 401,961 |

**Near and below 100 % collateralisation (`D > TC`):** the liquidator still receives `1+b` per cUSD until
the collateral is gone (`repaid = TC/(1+b)`, `slashed = TC`); the incentive never disappears while `TC > 0` and
`d < d*`. The bonus in this regime is paid by **cUSD holders**, not tranche depositors: the write-off is
`D − TC/(1+b)`, i.e. `b·TC/(1+b)` more than the raw shortfall `D − TC`. Everything not recovered reaches cUSD holders via
`writeOff → recognizeBadDebtInCredit` (`Stablecoin.sol:L159-L167`) — `badDebt` rises, `backing()` falls, exit
quotes follow `(backing/supply)²`.

### LIQUIDATOR offline (single permissioned role)

`liquidate` is wired to LIQUIDATOR only (`Registry.sol:L458-L459`); `D3_LiquidatorOffline.t.sol::test_nobodyElseCanLiquidate`
shows borrower, depositor, MEV searcher and even the account holding GUARDIAN+GOVERNOR+KEEPER all revert with
`AccessManagedUnauthorized`. While the role is offline, health degrades from two sources and nobody can act:

1. **Premium accrual alone** (floating `totalDebt = scaledDebt·index()` is a view, so it grows with no transaction;
   anyone may also realise it with `chargePremium()`). From `h = 1.008` at 20 % UW + 8.1 % liquidity:

   | offline | health | debt (from 500) |
   |---|---|---|
   | 1 h | 1.00797 | 500.016 |
   | 1 d | 1.00722 | 500.385 |
   | 7 d | 1.00258 | 502.704 |
   | 30 d | 0.98497 | 511.693 |

2. **Price path** −1 %/day from `h = 1.008`, premium realised daily by a third party:

   | day | health | `unrecoverableDebt` |
   |---|---|---|
   | 1 | 0.9972 | 0 |
   | 7 | 0.9345 | 0 |
   | 14 | 0.8663 | 0 |
   | 21 | 0.8031 | 8.03 (insolvent) |
   | 30 | 0.7286 | 54.83 |

The mechanism handed to WS-G: with the liquidator absent, the market passes `h = 0.816` (the point where any
liquidation would still have recovered *everything*) after ~20 days of a gentle −1 %/day decline; from then on every
day of delay converts collateral shortfall into cUSD bad debt at the full rate of the price move plus the premium.
No test fails here because the code does what it says; this is a liveness/centralisation design point, recorded as
D-6 (Low) below.

---

## Findings

### [Medium] D-1 — One dead feed on a funded, staked tranche bricks the market, **including floating `repay`** (P11, M-1 regression)
**Location:** `contracts/cap/Tranche.sol:L216-L219` (`getPrice`), `:L177-L181` (`totalCapital`); `contracts/cap/market/BaseMarket.sol:L292-L297` (`totalCapital`), `:L482-L485` (`_earnsPremium`), `:L435-L475` (`_chargePremium`); `contracts/cap/market/FloatingMarket.sol:L75-L80` (`repay`), `:L170-L185` (`_chargePremium`); `contracts/cap/oracle/Oracle.sol:L72-L101`.
**Impact:** As long as one tranche with `totalAssets > 0` cannot be priced (stale past `staleness`, answer `≤ 0`, adapter/feed reverting, sources cleared), every call that walks `totalCapital` reverts with `InvalidPrice`: `healthiness`, `maxLiquidatable`, `recoverableDebt`, `unrecoverableDebt`, `creditLimit`, `availableCredit`, `borrow`, `liquidate`, `writeOff`, `setTranches`/`createTranche`, `lockedValue`/`unlockedSupply` of the dead tranche and of **every tranche senior to it** (`lockedValue` walks juniors first, `BaseMarket.sol:L279-L288`). New in this round: `_earnsPremium` (L484) prices each staked tranche, so `_chargePremium` and therefore **`FloatingMarket.repay`, `chargePremium`, `setMarketMultiplier` revert too** whenever the dead tranche has opted-in shares and there is any premium to distribute (always, outside the same block as the last charge). Fixed-market `repay` still works; fixed `borrow/borrowMore/extend/extendAdmin/liquidate/writeOff` do not. Debt keeps compounding on the index for the whole outage (view-only), so the borrower is charged for a period during which it could not repay, and the liquidator cannot act during exactly the price move that would need it. Depositors of every senior tranche cannot exit (`unlockedSupply` reverts). Recovery is GOVERNOR-only via `Oracle.setSource` — and the only options are (a) wait for the feed, (b) widen `staleness` to accept the stale answer, (c) point at another adapter (a constant-price contract qualifies, since `setSource` only requires a non-zero answer).
**Likelihood:** No attacker needed. Any Chainlink feed whose heartbeat exceeds the configured `staleness` during a quiet period (24 h-heartbeat feeds are common for long-tail assets), a deprecated/paused aggregator (reverts ⇒ `success == false` ⇒ 0), an L2 sequencer outage longer than `staleness`, or a feed that prints `0`/negative. The market owner (third party) chooses tranche assets; `Registry._deployTranche` (`Registry.sol:L324`) checks only `price != 0` at creation — no secondary source, no heartbeat/staleness sanity, no decimals check — so a market owner can freely pick the flakiest priced asset for a junior tranche. Cost to cause: zero; cost to recover: a GOVERNOR transaction (subject to whatever timelock governs GOVERNOR).
**Exploit path (outage, not attack):** 1. Market with senior WETH ($400), mid X ($300, staked), junior WETH ($300); borrower owes $400; UW rate 20 %. 2. X's feed stops updating; `staleness` (1 h in the PoC) elapses. 3. `oracle.price(X) == 0`. Every call listed above reverts `InvalidPrice()`; borrower sends `repay(max)` with 500 cUSD in hand → revert. 4. Seven days later `totalDebt` has grown; nobody could liquidate, write off, or repay. 5. GOVERNOR re-points the source; borrower pays the accrued week. If the price of the *other* collateral fell meanwhile, the market may already be past `h = 0.816` with no liquidation possible during the fall.
**Proof:** `D5_P11_DeadFeed.t.sol` — `test_FAIL_borrowerCanRepayDuringOutage` (fails), `test_everyPricePathReverts` (passes; enumerates every revert), `test_fixedMarket_repayWorksOthersDoNot`, `test_secondarySourceFallback`, `test_zeroAnswerBricks`, `test_revertingFeedBricks`, `test_emptyOrDebtFreeDeadTrancheIsHarmless`.
```
Ran 8 tests for audit/v3/tests/scratch/D/D5_P11_DeadFeed.t.sol:D5_P11_DeadFeed
[FAIL: InvalidPrice()] test_FAIL_borrowerCanRepayDuringOutage() (gas: 409252)
[PASS] test_debtAccruesThroughOutageAndRecoveryNeedsGovernor() (gas: 355310)
[PASS] test_emptyOrDebtFreeDeadTrancheIsHarmless() (gas: 775302)
[PASS] test_everyPricePathReverts() (gas: 2159341)
[PASS] test_fixedMarket_repayWorksOthersDoNot() (gas: 4056978)
[PASS] test_revertingFeedBricks() (gas: 1065975658)
[PASS] test_secondarySourceFallback() (gas: 601125)
[PASS] test_zeroAnswerBricks() (gas: 366456)
```
What survived from round 2's fix: an **empty** dead tranche is harmless (`slash`/`totalCapital` short-circuit on zero assets) and a **debt-free** dead tranche can exit (`lockedValue == 0` never prices). Neither covers the case that matters — a funded tranche on a market with debt.
**Recommendation:** (1) `_earnsPremium` should test `ITranche(tranche).totalAssets() > 0`, not `totalCapital() > 0` — the comment's intent ("shares survive a wipeout") is an asset check and needs no price; this alone restores `repay`, `chargePremium` and `setMarketMultiplier` during an outage. (2) Require a secondary source (or an explicit governor opt-out) for any asset used as tranche collateral, checked in `_deployTranche`. (3) Give the liquidation path a bounded last-known-price fallback (store `(price, updatedAt)` in Tranche on every successful read; allow `liquidate`/`writeOff`/`unlockedSupply` to use it while `now − updatedAt ≤ maxFallbackAge`, and only for those paths, never for `borrow`). Second-order: a fallback price used by `liquidate` could over-value a crashed asset by up to the fallback age's move — bound the age tightly (minutes to a few hours) and keep `borrow` strict. (4) Document that GOVERNOR's `setSource` is a liveness-critical emergency action and keep it outside any long timelock.
**Invariant broken:** none in the plan (liveness). New: I-D4 below.

### [Medium] D-2 — For `lt·(1+bonus) > 1e27` GUARDIAN can write off a *healthy* market: cUSD holders lose, tranche collateral untouched, borrower forgiven (P13, I38)
**Location:** `contracts/cap/market/BaseMarket.sol:L380-L386` (`_writeOff`), `:L263-L267` (`unrecoverableDebt`), `:L230-L234` (`healthiness`), `:L89-L96` (`setLt`); `contracts/cap/InterestRateModel.sol:L180-L184` (`_setLiquidationBonus`); `contracts/cap/market/FloatingMarket.sol:L104-L113`, `FixedMarket.sol:L151-L160` (`writeOff`).
**Impact:** `writeOff` is bounded by `U = D − TC/(1+b)` while liquidation requires `h = TC·lt/D < 1`. Both hold simultaneously iff `TC/(1+b) < D ≤ TC·lt`, a non-empty band iff **`lt·(1+b) > 1e27`**. Inside it the market reports itself healthy, `liquidate` reverts `Healthy()`, yet `unrecoverableDebt() > 0` and GUARDIAN's `writeOff` succeeds: `recognizeBadDebtInCredit` raises `badDebt`, `backing()` drops for every cUSD holder, **no tranche loses a token**, and the borrower's debt is cut by the written-off amount (`scaledDebt = remainingScaled` / `debt[id] -= amount`). This is the brief's tiebreaker shape — a depositor (cUSD holder) loses while the system reports itself covered — with the loss going to a third-party borrower. In the PoC: TC $900, D $850, `h = 1.0059`, write-off $31.82 (3.5 % of supply), backing 0.9665.
**Likelihood:** Governance range only. With `b ≤ 0.1` the band exists iff `lt > 1/(1+b)`: at the deploy bonus (2 %) that is `lt > 0.98039e27`; at the maximum bonus (10 %) `lt > 0.90909e27`. `setLt` (GUARDIAN) accepts anything in `(buffer, 1e27]` and `setLiquidationBonus` (GOVERNOR) anything in `[0, 0.1e27]`; neither checks the product, and the two live in different contracts (IRM has no view of market `lt`). At deploy defaults `0.8·1.02 = 0.816 < 1` — band empty, verified by sweep. A guardian acting *honestly* on the `unrecoverableDebt()` signal (the canonical write-off trigger, and what a keeper bot would poll) triggers the loss; a malicious guardian has cheaper tools (`recognizeBadDebtInReserve`), so the finding is about incoherence under legitimate parameters, not guardian malice.
**Exploit path:** 1. GOVERNOR sets bonus 0.10; GUARDIAN sets `lt = 0.95` (e.g. for a stablecoin-collateral market — the natural place for a high `lt`); owner sets `ltv = 0.85`. 2. Borrower draws $850 against $1000. 3. Collateral drifts −10 % ⇒ TC $900, `D/TC = 0.944 ∈ (0.909, 0.95]`. 4. `healthiness() = 1.0059`; `liquidate` → `Healthy()`. `unrecoverableDebt() = 31.82`. 5. GUARDIAN (or its bot) calls `writeOff()`: `badDebt += 31.82`, `creditBackedSupply −= 31.82`, `totalDebt = 818.18`, both tranches still hold 1000 tokens. 6. Borrower's obligation is $31.82 smaller; cUSD holders' backing is 3.5 % lower; the market is now "healthier" (h = 1.045) having paid nothing.
**Proof:** `D6_P13_WriteOffHealthy.t.sol` — `test_FAIL_I38_unrecoverableImpliesUnhealthy` (fails), `test_writeOffSucceedsWhileLiquidateRevertsHealthy`, `test_fixedMarket_sameBand`, `test_bandEmptyAtDeployDefaults`, `testFuzz_bandExistsIff_ltTimesOnePlusBonusAboveOne` (256 runs over `lt ∈ [0.2,1]`, `b ∈ [0,0.1]`, ratio inside the band: always healthy *and* unrecoverable).
```
[FAIL: I38: unrecoverableDebt > 0 must imply healthiness < 1: 1005882352941176470588235294 >= 1000000000000000000000000000] test_FAIL_I38_unrecoverableImpliesUnhealthy() (gas: 566068)
  totalCapital     : 900.000000000000000000
  totalDebt        : 850.000000000000000000
  healthiness      : 1.005882352941176470588235294
  unrecoverableDebt: 31.818181818181818182
[PASS] test_writeOffSucceedsWhileLiquidateRevertsHealthy() (gas: 818412)
  written off       : 31.818181818181818182
  backing / supply  : 0.966507177033492822966315789
[PASS] testFuzz_bandExistsIff_ltTimesOnePlusBonusAboveOne(uint256,uint256,uint256) (runs: 256, ...)
```
**Recommendation:** Two independent guards, both cheap: (a) `_writeOff` reverts `Healthy()` when `healthiness() >= 1e27` — a healthy market by definition has nothing to write off; (b) enforce `lt·(1e27 + liquidationBonus) ≤ 1e27` in `setLt` (read the bonus from the IRM) and, in `_setLiquidationBonus`, cap the bonus at `1e27/maxLt − 1` for a governor-declared `maxLt` (or simply document that `lt ≤ 1e27/(1+b_max) = 0.909e27` is a hard protocol bound and enforce that constant in `setLt` and `Registry.initialize`, `Registry.sol:L106`). Second-order of (a): in the band the market can carry `U > 0` with no action possible; that is correct — it is healthy, and a further price fall makes it liquidatable first (`M == R` drains it, leaving the true remainder for `writeOff`).
**Invariant broken:** **I38** — holds iff `lt·(1+b) ≤ 1e27`; the setters do not enforce it.

### [Medium] D-3 — Design: an expired, unpaid fixed loan on a healthy market cannot be liquidated; underwriter capital stays locked for 6 months to 2.7 years at deploy rates
**Location:** `contracts/cap/market/BaseMarket.sol:L353-L358` (`_liquidate` requires `healthiness() < 1e27`); `contracts/cap/market/FixedMarket.sol:L113-L124` (`extendAdmin`), `:L310-L319` (`_rollFromNow`), `:L127-L134` (`repay`); `expiry[id]` is read nowhere on the liquidation path.
**Impact:** Expiry has no enforcement. After `expiry[id]` the only lever is KEEPER `extendAdmin` (after `grace`), which *extends* the loan and adds `(arrears + term)·rate` to the debt; health falls only through that accrual. With no price move and a max-ltv draw (`h₀ = lt/ltv = 1.143`), the loan becomes liquidatable purely by premium after:

| rates | `extendAdmin` calls | days from borrow to `h < 1` | debt then (from 700) |
|---|---|---|---|
| deploy defaults: no liquidity slopes (rate 0), UW 20 % | 8 | **248** | 800.97 |
| harness slopes at ~40 % utilisation (7.6 %) + UW 20 % | 6 | **186** | 809.92 |
| UW 5 %, no slopes | 32 | **992** | 801.66 |

Until then: (i) the underwriters' `lockedValue = D/(lt − buffer)` (`BaseMarket.sol:L277`) — $1000 of the $1000 in the PoC — cannot be withdrawn; (ii) the liquidity premium leg is charged to the loan, minted to cUSD holders and ultimately recovered from the tranches' own collateral (net leakage `r_liq·(1+b) + b·r_uw` per year of debt: ≈ 8.9 %/yr at harness rates, 0.4 %/yr at deploy rates); (iii) the underwriter premium the tranches "earn" is minted against a debt whose only source of repayment is their own collateral — circular; (iv) at eventual liquidation they lose `D'·(1+b)` on a `D'` that has grown 14 %. A borrower who walks away keeps the principal with no penalty; `repay` a year late costs exactly the original debt if no `extendAdmin` ran (`test_lateRepayHasNoPenalty`: 700.0 repaid 365 days late).
**Likelihood:** Borrowers are third parties (Matt). Cost to the borrower of defaulting on-chain: nothing beyond forfeiting the borrower role. Cost to underwriters: capital locked for the durations above with no on-chain remedy; dependent on KEEPER actually calling `extendAdmin` every ~31 days (if KEEPER does nothing, the health never moves and the loan is open forever — `test_lateRepayHasNoPenalty` shows debt unchanged after a year).
**Exploit path:** 1. Underwriters fund $1000 into a fixed market (lt 0.8, ltv 0.7). 2. Borrower draws the maximum ($700 incl. upfront premium, 30-day term). 3. Expiry passes; borrower does nothing; `liquidate` → `Healthy()`; `extendAdmin` → `StillInGracePeriod()` for `grace`. 4. KEEPER extends every ~31 days; each call adds ~1.7 % to the debt. 5. Day 248: `h < 1`; LIQUIDATOR clears it, slashing $817 of collateral (`800.97·1.02`). Borrower net: +$700. Underwriters: −$817 plus 248 days of locked capital, offset by ≈ $100 of underwriter premium they were paid in cUSD minted against their own collateral.
**Proof:** `D8_FixedExpiry.t.sol` — `test_timeline_deployDefaults_uw20`, `test_timeline_withLiquiditySlopes_uw20`, `test_timeline_uw5`, `test_lateRepayHasNoPenalty` (all pass; they document the mechanism and timeline).
```
[PASS] test_timeline_deployDefaults_uw20()
  debt at borrow            : 699.999999999999999999
  health at borrow          : 1.142857142857142857144489796
  extendAdmin calls          : 8
  days from borrow to h < 1  : 248
  debt when liquidatable    : 800.974862210739826062
[PASS] test_timeline_uw5()
  extendAdmin calls          : 32
  days from borrow to h < 1  : 992
[PASS] test_lateRepayHasNoPenalty()
  debt repaid a year late (no extendAdmin ran): 699.999999999999999999
```
**Recommendation:** Make maturity a liquidation trigger: in `FixedMarket.liquidate`, allow the call when `block.timestamp ≥ expiry[id] + grace` regardless of `healthiness()`, sized to the loan (`repaid ≤ debt[id]`) with the same `1+b` slash — this crystallises the underwriters' loss at `D·(1+b)` instead of `D'·(1+b)` and frees the remaining collateral immediately. Alternatively let `extendAdmin` be permissionless after grace so the health erosion cannot stall on KEEPER. Second-order: a maturity-triggered liquidation on a *healthy* market slashes junior tranches at the bonus for a debt that was fully covered — the bonus should probably be zero or reduced for maturity liquidations, and `maxLiquidatable`'s health-targeting formula does not apply (use `min(amount, debt[id], R)`). WS-G models the cascade of many expired loans hitting one `extend` `Unhealthy()` gate (P7).
**Invariant broken:** none listed.

### [Low] D-4 — Permissionless premium accrual on an insolvent market grows the eventual write-off by ~0.077 % of debt per day of GUARDIAN delay; the unbacked cUSD goes to residual-capital tranche stakers and the cUSD vesting pot (P9)
**Location:** `contracts/cap/market/FloatingMarket.sol:L98-L101` (`chargePremium`), `:L170-L185`; `contracts/cap/market/BaseMarket.sol:L435-L475` (`_chargePremium`), `:L482-L485` (`_earnsPremium`); `contracts/cap/market/FixedMarket.sol:L113-L124` (`extendAdmin`).
**Impact:** Once `unrecoverableDebt > 0`, every `chargePremium()` (anyone) / `extendAdmin` (KEEPER) mints credit-backed cUSD on debt that is known to be unrepayable. Measured on $500 debt, TC $100 (U = 401.96) at 20 % UW + 8.1 % liquidity: **+0.3854 cUSD of bad debt per day** (0.077 %/day, 28.1 %/yr) — $770/day per $1M of unrecoverable debt. Split per day: 0.2604 to senior tranche stakers, 0.0137 to junior stakers (both still hold $50 of residual capital, so `_earnsPremium` passes), 0.1113 to the stablecoin pot (liquidity leg). After a liquidation drains every tranche, nothing is eligible and **all** of it (0.3098/day) is `fundCreditBacked` into the stablecoin's own vesting pot — opted-in cUSD holders are paid with cUSD that the write-off then charges to all cUSD holders (net transfer from non-opted-in to opted-in holders). On fixed markets one `extendAdmin` on a $400 insolvent loan raised U from 315.11 to 325.30 (+3.2 %) in a single call.
**Likelihood:** Requires an insolvent market (U > 0) and GUARDIAN delay; anyone can poke `chargePremium`, and `repay`/`liquidate`/`borrow` do it implicitly. Linear in delay, no attacker profit beyond stakers of the surviving tranches collecting premium on a dead debt.
**Exploit path:** 1. Market insolvent at T (U₀ = 401.96). 2. Anyone calls `chargePremium()` daily. 3. GUARDIAN writes off at T+1d: 402.35 instead of 401.96. 4. Senior stakers claim 0.26 cUSD/day of premium for the duration; cUSD holders carry all of it as bad debt.
**Proof:** `D7_P9_InsolventPremium.t.sol` — `test_FAIL_writeOffIndependentOfGuardianDelay` (fails), `test_recipientsOfUnbackedPremium_residualCapital`, `test_recipientsOfUnbackedPremium_drained`, `test_fixed_extendAdminMintsOnInsolventLoan`.
```
[FAIL: bad debt recognised must not grow with guardian delay: 402346206759470786673 != 401960784313725490196] test_FAIL_writeOffIndependentOfGuardianDelay()
  written off at T          : 401.960784313725490196
  written off at T+1d       : 402.346206759470786673
  extra bad debt per day    : 0.385422445745296477
[PASS] test_recipientsOfUnbackedPremium_residualCapital()
  liquidity premium / day   : 0.111313758628246316
  underwriter premium / day : 0.274108687117050162
    -> senior tranche       : 0.260403252761197654
    -> junior tranche       : 0.013705434355852508
    -> stablecoin pot       : 0.111313758628246316
[PASS] test_recipientsOfUnbackedPremium_drained()
  minted into stablecoin pot on a fully drained market, per day: 0.309849417167787365
[PASS] test_fixed_extendAdminMintsOnInsolventLoan()
  unrecoverable before extendAdmin: 315.111469245232339512
  unrecoverable after  extendAdmin: 325.300985852384856831
```
**Recommendation:** In `_chargePremium` (floating) and `_applyPremium` (fixed), compute the premium only on the recoverable part: charge on `min(totalDebt, recoverableDebt())` (floating: scale the two index deltas by `R/D`; fixed: `chargeableDebt = min(debt[id], R)`) — or simpler, skip the mint entirely while `unrecoverableDebt() > 0` and let the index freeze (`lastPremiumUpdate = block.timestamp` without minting). Second-order: freezing the index also freezes the *recoverable* part's premium, which is a small under-charge relative to the alternative of minting unbacked supply; and both variants add a `totalCapital()` walk (prices) to `repay`, which interacts with D-1 — do the `_earnsPremium` fix first. Alternatively make `writeOff` permissionless but bounded by `unrecoverableDebt()` (it already is), accepting the P12 front-run concern WS-E owns.
**Invariant broken:** I30 as a ghost — `Σ totalDebt == creditBackedSupply` still holds, but the coverage ratio the plan records keeps falling with no state change other than time.

### [Low] D-6 — Liquidation is a single permissioned role; nobody else can act while health degrades
**Location:** `contracts/cap/Registry.sol:L458-L459` (LIQUIDATOR wiring); `contracts/cap/market/FloatingMarket.sol:L83-L96`, `FixedMarket.sol:L137-L148` (`restricted`).
**Impact/Likelihood/Proof:** See "LIQUIDATOR offline" above and `D3_LiquidatorOffline.t.sol` (both tests pass). With the role absent, a −1 %/day drift takes a market from `h = 1.008` past the full-recovery point (`0.816`) in ~20 days and to `U = 54.8` on $500 (11 %) by day 30, all of which lands on cUSD holders via D-2's `writeOff`. Depends entirely on one key's uptime; the gas-spike behaviour (item 8) makes it worse: the liquidator's transaction competes for inclusion with no backup bidder.
**Recommendation:** Allow permissionless liquidation after the LIQUIDATOR has had a head start (e.g. `h < 1` for more than `N` blocks/minutes, or `h < 0.9`), or at least grant the role to several independent operators. Second-order: permissionless liquidation re-opens the oracle-deviation MEV surface of Table 2; a short grace for the trusted role keeps the best of both.
**Invariant broken:** none.

### [Informational] D-5 — Waterfall dust: underpayment is bounded by one token unit of the last tranche that delivered; not exploitable (P10)
**Location:** `contracts/cap/Tranche.sol:L77-L84` (`slash` floor), `contracts/cap/market/BaseMarket.sol:L362-L373`.
**Analysis:** `assets = ⌊value·unit/price⌋`, `slashedValue = ⌊assets·price/unit⌋ ≤ value`; the waterfall subtracts the *delivered* value and continues, so every tranche except the last one visited passes its floor remainder on. The total shortfall `repaid·(1+b) − slashed` is therefore `< price/unit` of the **most senior tranche that delivered** (`< 1 sat` for WBTC, `< 1e-18 WETH`), never a sum over tranches. Measured: WBTC senior at $35k, $21,705 liquidation ⇒ underpayment **$0.000207** (< 1 sat = $0.00035); 2-dec $1 senior at $0.60 ⇒ $0.0028. Fuzzed over 256 repay sizes: always below one unit, and net-positive for the liquidator whenever `repaid > unit/b` (50 sats ≈ $0.0175). A market owner cannot make liquidations systematically unprofitable: the coarsest unit is bounded by what GOVERNOR has onboarded to the oracle (the only gate, `Registry.sol:L324`); only a 0- or 2-decimal high-priced token would matter, and none is plausible. A depositor sizing capital changes nothing (a 1-sat tranche delivers its sat and passes the rest on). The "dust left after the senior is uncollected" comment survives; the liquidator's loss is real but sub-cent.
**Proof:** `D4_P10_Dust.t.sol` (3 tests, all pass; `testFuzz_underpaymentAlwaysBelowOneUnit` 256 runs).
```
[PASS] test_underpaymentBoundedByOneSeniorUnit()
  repaid (cUSD burned)     : 21705.069124423963133641
  owed  = repaid*(1+b)     : 22139.170506912442396314
  slashed (USD delivered)  : 22139.170300000000000000
  underpayment             : 0.000206912442396314
  one senior unit (USD)    : 0.000350000000000000
```
**Recommendation:** none required. If desired, round `assets` up when the tranche can afford it (`assets+1 ≤ total`) so the liquidator is never short; second-order: the tranche is then short by < 1 unit instead, which is the right side for the protocol's promise.

### [Informational] D-7 — Oracle: future stamps, no scale check in `setSource`, no min/max clamp, no L2 sequencer feed, unbounded adapter gas, `decimals > 18` floors
**Location:** `contracts/cap/oracle/Oracle.sol:L35-L43` (`setSource`), `:L80-L92` (`_read`), `:L95-L101` (`_isStale`); `contracts/cap/oracle/ChainlinkAdapter.sol:L20-L32`.
**Observations** (all demonstrated in `D9_Oracle.t.sol`, 6 tests pass):
- **Future stamp** (`_isStale` L100): an answer with `updatedAt > block.timestamp` is fresh forever — a feed at `now + 365 d` still priced 300 days later with `staleness = 1`. Chainlink cannot produce this; a custom adapter (e.g. a rate/`pricePerShare` source that returns a constant timestamp) can. Bound it: treat `lastUpdated > now + tolerance` as unusable.
- **`setSource` dry-run checks only `!= 0`** (R2-L3 regression): an adapter answering `1e8` (an un-normalised 8-dec feed) or `1e40` is accepted; the asset is then priced at `1e-10` or `1e22` USD and every tranche on it is mis-valued by 10 orders of magnitude. Suggest a sanity band against the previous answer (or an explicit `expectedPrice ± tolerance` argument) on `setSource`.
- **No `minAnswer`/`maxAnswer` inspection** (documented at `ChainlinkAdapter.sol:L9-L10`). During a crash below a feed's `minAnswer` the aggregator reports `minAnswer`, `d > 0` becomes unbounded and Table 2 goes deeply negative: nobody liquidates and the market drifts into write-off. Real risk only for feeds that still publish active bounds; onboarding must check.
- **No L2 sequencer-uptime feed** while `foundry.toml` targets `monad`, `tempo`, `megaeth`, `katana`. Concrete risk: after a sequencer halt, the first L2 blocks execute a backlog of forced-inclusion / delayed transactions against the last pre-halt answers, whose `updatedAt` is within `staleness` of the (jumped) L2 timestamp only if the halt was shorter than `staleness` — and for a long halt the market is bricked per D-1 instead. In the short-halt case a liquidator (or borrower drawing at the old price) acts on a price that is `staleness`-old at best while the market has repriced; Chainlink's recommendation (sequencer feed + grace period) is absent, and none of the four targets has a canonical uptime feed yet, so the mitigation would have to be a governor-set "halt flag" or a per-chain grace after any gap in feed updates. On chains with no Chainlink at all (Tempo, MegaETH today) the adapter set is Cap's own responsibility and the future-stamp/scale gaps above apply in full.
- **Unbounded adapter gas** (`_read` L85 forwards all gas): a primary that fails with `INVALID` (consumes all forwarded gas) leaves the caller 1/64 of its gas for the secondary; with a 500k-gas transaction that is ~7.8k, so the secondary read OOGs and the hop answers zero — the fallback is defeated (`test_revertingFeedBricks` burned 1.07e9 gas). Cap the staticcall gas (e.g. `gas: 200_000`).
- **`decimals > 18`** floors (`1e20+99` at 20 dec → exactly `1e18`), `decimals ≥ 96` overflows `10**` → staticcall fails → 0. Harmless.
- **Chain product precision**: 3 hops lose at most 2 wei of `1e18` (`test_threeHopPrecision`: exact `…6298`, got `…6296`). Harmless.
- **Congestion / gas spike — what fails first:** the LIQUIDATOR's single transaction (D-6). Reads are O(tranches × hops) staticcalls (~30–40k each); `liquidate` walks `totalCapital` at least four times (health, threshold, recoverable, then per-tranche `slash` price) — ~0.5 M gas for a 3-tranche market — fine on L1/L2 but the size of `maxLiquidatable` at `h ≈ 0.999` is already 58 % of debt, so the *first* liquidation is the large one and cannot be split into cheaper pieces by choice of `amount` alone (it can — `amount` is honoured — but gas is per call not per dollar). Nothing in the oracle itself degrades with congestion; staleness windows should be set with the chain's realistic inclusion delay in mind.
- **Test harness**: `FEED_STALENESS = 3650 days` on every mock feed means no shipped test observes a stale feed against a funded market or the sequencer scenario. Flagged to WS-F.

---

## Appendix: gas & style
- `BaseMarket.healthiness()` uses half-up `rayDiv`: for `debt = threshold + k` with `k < debt/1e27` the health rounds to exactly `1e27`, so `_liquidate` reverts `Healthy()` while `maxLiquidatable() > 0` (it uses the strict `debt > threshold`). Sub-wei window; only affects dust.
- `_liquidate` recomputes `maxLiquidatable()` (three `totalCapital` walks) after `FloatingMarket.liquidate` already took it; cache the value across the two.
- `FloatingMarket.writeOff` calls `unrecoverableDebt()` inside `_repayWithin` and again inside `_writeOff` (two more walks).
- `Oracle._price` re-reads a hop's primary and secondary through separate staticcalls; a hop whose primary is stale still pays for the failed primary each read.
- `Tranche.slash` emits `Slashed(recipient, assets, slashedValue)` but `BaseMarket.Liquidate` reports only the USD sum; indexers reconstructing per-tranche token flows need both.

## Invariants
- **I38 broken** in the governance range `lt·(1+liquidationBonus) > 1e27` (D-2); holds at deploy defaults (`0.816e27`).
- **I30** holds as an equality (verified incidentally in D7: `Δ creditBackedSupply == Δ totalDebt == liq + uw`), but its coverage-ratio ghost decays with time alone on an insolvent market (D-4).
- New invariants the code implies:
  - **I-D1** `repaid·(1+b) − slashed < price_last/unit_last`, where `last` is the most senior tranche that delivered non-zero value in the waterfall (verified, `D4`).
  - **I-D2** `maxLiquidatable() == min(debt, recoverableDebt()) ⇔ healthiness() ≤ (1+b)·lt`, and `unrecoverableDebt() > 0 ⇔ healthiness() < (1+b)·lt` (verified over a full price sweep, `D1`).
  - **I-D3** After `liquidate(maxLiquidatable())` with `(1+b)·lt < h < 1`, `healthiness() == targetHealth` within rounding (verified, `D1`).
  - **I-D4 (liveness)** For every funded tranche `t` with `stakedSupply(t) > 0` on a market with `totalDebt > 0`: `oracle.price(asset(t)) != 0` is a precondition of `repay`, `liquidate`, `writeOff`, `borrow`, `chargePremium` and of `unlockedSupply` of every tranche senior to `t` (D-1).
  - **I-D5** `writeOff` should imply `healthiness() < 1e27` at the time of the call (D-2 recommendation).

## Hypotheses
- **P9 — CONFIRMED (Low).** `chargePremium`/`extendAdmin` keep minting on an insolvent market; +0.077 %/day of debt at 28 % combined rate; recipients are residual-capital tranche stakers (weight-split) and the stablecoin pot, or the pot alone once drained. Failing test `D7::test_FAIL_writeOffIndependentOfGuardianDelay`.
- **P10 — REFUTED as Medium, CONFIRMED as behaviour (Informational).** `slashed < repaid·(1+b)` happens on every coarse-asset liquidation but is bounded by one unit of the last delivering tranche (< 1 sat); no path to systematic unprofitability without GOVERNOR onboarding a 0–2-decimal high-priced asset.
- **P11 — CONFIRMED (Medium), worse than hypothesised.** Beyond the M-1 list, `_earnsPremium` now prices every staked tranche, so floating `repay`, `chargePremium` and `setMarketMultiplier` also revert during the outage. Round-2 mitigations (empty tranche, zero-lock exit) survive but do not cover a funded tranche with debt. Failing test `D5::test_FAIL_borrowerCanRepayDuringOutage`.
- **P13 — CONFIRMED (Medium, governance range).** Band exists iff `lt > 1/(1+b)` (`> 0.98039e27` at the deploy bonus, `> 0.90909e27` at the maximum bonus); empty at deploy defaults. Failing test `D6::test_FAIL_I38_unrecoverableImpliesUnhealthy`; fuzzed band characterisation passes 256/256.
- **I38 — BROKEN** conditionally (see above).
- **Fixed-loan expiry (item 7) — CONFIRMED (Medium, design).** 186–992 days to liquidatable by accrual alone; no penalty on late repay; hand-off to WS-G for the cascade.
- **Liquidator liveness (item 2) — CONFIRMED (Low, design).** Single role; −1 %/day reaches the full-recovery boundary in ~20 days.
