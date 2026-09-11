# WS-E — Interest-rate model, utilization EMA, oracle stack

Files read end to end: `contracts/cap/InterestRateModel.sol`, `contracts/cap/oracle/Oracle.sol`,
`contracts/cap/oracle/ChainlinkAdapter.sol`, `contracts/utils/MathUtils.sol`,
`contracts/utils/WadRayMath.sol`, `contracts/interfaces/{IInterestRateModel,IOracle,IChainlink}.sol`,
and the consumers `contracts/cap/Tranche.sol`, `contracts/cap/Stablecoin.sol`,
`contracts/cap/market/{BaseMarket,FixedMarket,FloatingMarket}.sol`.

PoCs: `audit/tests/scratch/E/*.t.sol`. Run with
`FOUNDRY_TEST=audit/tests/scratch/E forge test --match-path 'audit/tests/scratch/E/*' -vv`
(scoped to this directory because another workstream's in-progress `audit/tests/invariants/CapHandler.sol`
does not compile at the time of writing; `FOUNDRY_TEST=audit/tests` will work once it does).
Result on current code: **12 failed, 3 passed** — every failure is intended; the 3 passes are sanity/number-printing tests.

Summary: 1 Critical, 1 Medium, 4 Low, 6 Informational.

---

### [CRITICAL] Oracle answers 8-decimal USD, Tranche consumes it as 18-decimal USD — every collateral value in the protocol is 1e10x too small
**Location:** `contracts/cap/oracle/Oracle.sol:16-19` (`DECIMALS = 8`, `ONE = 1e8`), `contracts/cap/oracle/ChainlinkAdapter.sol:28,59-61` (normalises to 8); consumed at `contracts/cap/Tranche.sol:83-89` (`slash`), `:274` (`unlockedSupply`), `:282` (`totalCapital`), `:287` (`activeCapital`). Documented scale: `contracts/interfaces/ITranche.sol:59-61,153-158` ("USD (18 decimals)"); `contracts/interfaces/IOracle.sol:25-28` ("Every adapter answers in {DECIMALS} fixed point... not negotiable per adapter").
**Impact:** `Tranche.totalCapital = totalAssets * price / 10**decimals()` yields USD in the *price's* scale. With the only shipped adapter that is 8 decimals, so `totalCapital`, `activeCapital`, `variableCreditLimit`, `debtLiquidationThreshold`, `recoverableDebt` and `lockedValue`-to-assets conversions are all 1e10x off against 18-decimal cUSD debt. Three consequences, all demonstrated:
1. Borrowing is capped at 1e-10 of intended: 10 WETH at $2,000 opens **1e12 wei = 0.000001 cUSD** of credit instead of $10,000 (fail-closed, protocol unusable).
2. The dust that *can* be borrowed locks the tranche: 1e-6 cUSD of debt makes `unlockedSupply` lock **71 %** of a $20k tranche (`lockedAssets = lockedValue * 1e18 / price8`), so underwriters cannot redeem.
3. Liquidation is fail-**open** by 1e10x: `slash` converts `value * unit / price8`, so a $6e-7 liquidation resolves to 1e19 wei of WETH, capped at the whole tranche. **The liquidator burns 5.9e-7 cUSD and receives all 10 WETH ($6,000).** The tranche reports `slashedValue = 6e11` (i.e. "$6e-7") while $6,000 of real collateral leaves. Underwriters lose 100 % of their deposit on the first unhealthy block of any market.
Dollars at risk: the entire collateral of every tranche that ever has non-zero debt at the moment its market dips under `lt`. No attacker capital needed beyond the LIQUIDATOR role burning dust.
**Likelihood:** Certain on any deployment that prices collateral through the shipped `Oracle` + `ChainlinkAdapter` (there is no other adapter in `contracts/`). Note for WS-F: `contracts/deploy/service/DeployInfra.sol:37,81` does not deploy `contracts/cap/oracle/Oracle.sol` at all — it passes an externally supplied `users.oracle` (`DeployConfigs.sol:13`) into the Registry, so the scale contract between oracle and tranche is enforced nowhere in code or script; whichever oracle is plugged in, `Tranche` will silently adopt its scale. No unit or integration test exercises the production oracle against a tranche: `test/shared/CapDeployer.sol:91,139` feeds `MockOracle` prices of `1e18` while `test/shared/mocks/MockOracle.sol:17` declares `DECIMALS = 8` — the mock is 18-decimal in practice, so the entire 399-test suite is green against a scale the real oracle never produces. `test/unit/cap/oracle/*.t.sol` assert `2000e8` and never touch a tranche.
**Exploit path:** (the "attacker" is any LIQUIDATOR, or simply an honest liquidation)
1. Governance deploys, sets `Oracle.setSource(WETH, ChainlinkAdapter.price(feed))`, creates a market with a WETH tranche. Underwriter deposits 10 WETH ($20,000).
2. `market.creditLimit()` = 1e12 wei. Permissioned borrower draws it (1e-6 cUSD).
3. WETH falls to $600 (or any move that makes `healthiness < 1e27` on the 1e10-shrunk threshold; premium accrual alone will do it in time).
4. Liquidator deposits 5.9e-7 USDC → cUSD, calls `liquidate(recipient, max)`. `toSlash = 6e11`. `Tranche.slash`: `assets = 6e11 * 1e18 / 600e8 = 1e19` → capped at `totalAssets = 1e19` → `Vault.withdraw(WETH, 10e18, recipient)`.
5. Net: recipient +10 WETH ($6,000 real); underwriters −100 %; borrower keeps 1e-6 cUSD; `slashedValue` event says `6e11`.
**Proof:** `audit/tests/scratch/E/E1_OracleDecimals.t.sol` (real `Oracle` proxy + `ChainlinkAdapter` + `MockAggregator(8, 2000e8)` wired into a fresh `Registry`; see `RealOracleDeployer.sol`). Output on current code:
```
[FAIL: totalCapital is 1e10x below the documented scale: 2000000000000 != 20000000000000000000000] test_totalCapital_isDocumentedEighteenDecimalUsd()
  intended totalCapital (18-dec USD): 20000000000000000000000
  actual   totalCapital: 2000000000000
  ratio intended/actual: 10000000000
[FAIL: credit limit is 1e10x below intended: 1000000000000 != 10000000000000000000000] test_creditLimit_isTenThousandDollars()
[FAIL: 1e-6 cUSD of debt locks 71% of a $20k tranche: 2857142857145000000 < 9999998999285714286] test_dustDebtLocksMostOfTheTranche()
  intended locked WETH (wei): 714285714
  actual unlocked shares: 2857142857145000000
[FAIL: liquidator seized 1e10x more collateral than the debt cleared: 6000000000000000000000 > 600600000000] test_liquidation_takesWholeTrancheForDust()
  borrowed (cUSD wei): 1000000000000
  cUSD burned by liquidator (wei): 588235294118
  slashedValue reported by tranche: 600000000000
  WETH seized (wei): 10000000000000000000
  WETH left in tranche (wei): 0
  real USD value seized (18-dec): 6000000000000000000000
  USD the liquidator was owed (18-dec): 600000000000
[PASS] test_oracleAnswersEightDecimals()
```
**Recommendation:** Pick one scale and enforce it at the boundary. The smaller change is in `Tranche`: read `IOracle(oracle).DECIMALS()` once at init and compute `capital = assets * price * 10**(18 - oracleDecimals) / 10**decimals()` (and the inverse in `slash`/`unlockedSupply`), or have `Oracle` answer 18 decimals (`DECIMALS = 18`, `ONE = 1e18`, adapter normalises up) so every consumer's documented assumption becomes true. Either way: (a) make `MockOracle` honour its own `DECIMALS` and have `CapDeployer` feed prices at that scale so the suite fails on a mismatch; (b) add one integration test that deploys the real `Oracle` + `ChainlinkAdapter` under a tranche; (c) assert in `Registry._deployTranche` that `IOracle(oracle).DECIMALS()` equals what `Tranche` expects. Second-order: an 18-decimal `ONE` in `Oracle.price` changes chain composition rounding (each leg floors at 1e-18 instead of 1e-8, strictly better).
**Invariant broken:** I5 (liquidation is "profitable" by 1e10x — the bonus bound is meaningless), I8 in spirit (`variableCreditLimit` is not what `ltv` says), and the implicit invariant at `BaseMarket.sol:337-338` "the tranches never give up more than `1 + bonus` per unit of debt cleared" — proposed as new I17 below.

---

### [MEDIUM] H10 — the utilization EMA is defeated by a par, fee-less, instantly-reversible cUSD deposit held for one window; a borrower reprices a 30-day fixed loan at 23x the cost of doing so
**Location:** `contracts/cap/InterestRateModel.sol:181-189` (`fixedRatesAfterMint`), `:251-254` (`averageUtilizationAfterMint`), `:280-294` (`_accrueAverage`), `:302-305` (`_averagingWeight`), `:228-234` (band 5 min – 1 day); `contracts/cap/market/FixedMarket.sol:307-322`; `contracts/cap/Stablecoin.sol:162-187` (deposit/mint at par, no fee).
**Impact:** stcUSD holders (recipients of the liquidity premium, `BaseMarket.sol:441-444`) receive less than the curve prices for the whole term. Demonstrated: on a $1M / 30-day loan against an honest 80 % utilization, parking $10M USDC for the default 1-hour window cuts the liquidity premium from **8,966 to 6,311 cUSD (−2,655, −30 %)**; the parked capital costs ≈114 cUSD at a 10 % opportunity rate → **23x**. At the 5-minute floor the cost is 9.5 cUSD (279x). At the 1-day ceiling a $5M loan saves **20,890 cUSD for 2,740 of cost (7.6x)**. The design comment at `IInterestRateModel.sol:209-213` claims a cross-block manipulation "means standing behind an unwanted position for a real share of the period, exposed to everyone else the whole time" — a cUSD deposit is not an unwanted position: it is redeemable at par in the same block (`instantUnlockedSupply` rises by exactly the parked amount), earns nothing and risks nothing while `badDebt == 0`. The claim does not survive.
**Likelihood:** Actor: any permissioned BORROWER (the depositor can be anyone; only the borrow needs the role). Preconditions: `badDebt == 0` (else the round-trip pays the haircut), enough USDC to move utilization materially — the discount is a function of `D/S`, so the attack scales with the stablecoin's size, not the loan's. Cost: gas + opportunity cost of `D` for `averagingPeriod` (≤ 1 day). Since a fixed term is up to 30 days and the window is at most 1 day, `T/P ≥ 30` and the trade is profitable whenever `L · ΔR(D) · T > r · D · P`.
**Exploit path:** (default config: base 5 %, slope0 5 %, slope1 10 %, kink 80 %, P = 1 h; supply 10M, credit 8M)
1. t0: attacker deposits `D = 10M` USDC → 10M cUSD at par. Spot utilization 8/20.
2. t0 + P (or later): `averageSupplies() = (8M, 20M)`. `fixedRatesAfterMint(L=1M)` prices at `(9M)/(21M) = 42.9 %` → 7.68 % APR instead of `(9M)/(11M) = 81.8 %` → 10.9 % APR.
3. Attacker borrows 1M for 30 days; premium charged 6,311 cUSD.
4. Same tx or block: `stablecoin.redeem(10M)` — instant, at par (unlocked supply is `S + D + L − C − L = S − C + D`).
5. Net: attacker −114 (opportunity) +2,655 (premium avoided); stcUSD −2,655. Repeatable per loan.
**Proof:** `audit/tests/scratch/E/E2_EmaManipulation.t.sol`
```
[FAIL: a fully reversible deposit repriced a 30-day loan: 6311154598825831702544 != 8966376089663760896637] test_parkedDepositBuysADiscountOnTheWholeTerm()
  averaging period (s): 3600
  honest 30-day liquidity premium (cUSD): 8966.376089663760896637
  manipulated premium (cUSD): 6311.154598825831702544
  lenders lose (cUSD): 2655.221490837929194093
  attacker capital cost at 10% APR (cUSD): 114.155251141552511415
  profit multiple: 23
[FAIL: see log: profitable across the whole band] test_bandDoesNotChangeTheOutcome()
  period: 300     lenders lose: 2655.22   attacker cost @10% APR: 9.51
  period: 3600    lenders lose: 2655.22   attacker cost @10% APR: 114.16
  period: 86400   lenders lose: 2655.22   attacker cost @10% APR: 2739.73
[FAIL: profitable even at the longest permitted window: ...] test_maxWindowStillProfitableForALargerLoan()
  honest premium on $5M/30d: 54794.52   manipulated premium: 33904.11
  lenders lose: 20890.41   attacker cost @10% APR for 1 day on $10M: 2739.73
```
**Recommendation:** Averaging cannot fix this on its own because the manipulation is nearly free per unit time; the window would have to approach the term. Options, in order of preference: (1) price the fixed premium off `max(averageUtilizationAfterMint, spotUtilizationAfterMint)` — a parked deposit lowers both, but a deposit that is *withdrawn before the borrow* no longer helps, and a deposit still present at the borrow is real liquidity (this removes the "withdraw in the same block" cheapness: the attacker must keep `D` parked for the term or accept spot); (2) charge the fixed premium against the utilization *excluding* supply younger than one window (per-depositor timestamp or a "recent deposits" bucket), which makes the manipulation cost `D` for `T` rather than `P`; (3) at minimum, raise `MAXIMUM_AVERAGING_PERIOD` toward the maximum term and document that the band is a cost dial, not a fix. Second-order: (1) makes honest fixed borrowers pay spot when utilization has just risen, which is the conservative direction. Hand-off: formulas in §Formulas for WS-G `ema_manipulation.py`.
**Invariant broken:** none listed; proposed I18 below ("no reversible action can reprice a fixed premium").

---

### [LOW] H4(a) — `ChainlinkAdapter._withinBounds` fails open on a missing `aggregator()` hop, so a feed configured at its aggregator address skips the circuit breaker it publishes
**Location:** `contracts/cap/oracle/ChainlinkAdapter.sol:79-94`
**Impact:** An answer resting exactly on `minAnswer` (a LUNA-style clamp) is accepted as a price. The comment at L72-75 justifies fail-open for feeds that expose *neither* hop, but the code also fails open when `_source` **is** the aggregator (no `aggregator()` function, but `minAnswer()`/`maxAnswer()` right there). Chainlink publishes both proxy and aggregator addresses; pointing an entry at the aggregator is a realistic mistake that silently disables the only defence against the exact incident the comment cites. Collateral over-valued at the floor → `totalCapital` up → borrow → unrecoverable debt on correction (see §Formulas, over-borrow `= ltv · C · (f − 1)`).
**Likelihood:** Requires governance to configure a feed without the proxy hop AND the asset to crash through the feed's floor. Attacker cost: none, they only need the market to exist. Not demonstrable as an unprivileged exploit — hence Low.
**Exploit path:** 1. `setSource(asset, adapter.price(aggregatorAddr))`. 2. Asset crashes below `minAnswer`; aggregator reports the floor on a fresh stamp. 3. Every `totalCapital`/`healthiness` reads the floor; borrower draws `ltv · floorValue`; liquidation cannot reach; write-off lands on cUSD.
**Proof:** `audit/tests/scratch/E/E3_OracleFailOpen.t.sol::test_H4a_floorAcceptedWhenAggregatorHopMissing` — feed at `minAnswer = 100e8`, no `aggregator()`:
```
[FAIL: an answer resting on the published floor must be refused] test_H4a_floorAcceptedWhenAggregatorHopMissing()
  adapter accepted clamped answer: 10000000000
```
**Recommendation:** When the `aggregator()` staticcall fails, set `aggregator = _source` and continue to the bounds reads; only fail open when the bounds reads themselves fail. Consider also refusing an answer within a small band of the bound (e.g. ≤ 1.01 · min) since a clamped feed may report one unit inside it.
**Invariant broken:** none.

### [LOW] H4(b) — `Oracle._isStale` treats a future-dated answer as fresh forever
**Location:** `contracts/cap/oracle/Oracle.sol:181-192`
**Impact:** An entry whose adapter once returned `lastUpdated > block.timestamp` can never go stale: a feed that then falls silent is served at its last answer for the life of the configuration, and the backup is never consulted. Since `Tranche.getPrice` deliberately does not re-check age (`Tranche.sol:320-327`, "a stale feed arrives as a revert rather than as a number with an old timestamp") the whole protocol relies on this one check. The comment's rationale — a panic would take the market down — is satisfied equally by returning `true` (stale → backup), which is the fail-closed choice.
**Likelihood:** Real Chainlink feeds stamp `block.timestamp`; a future stamp needs a buggy/compromised adapter or the misconfiguration in H4(c) below. Low.
**Exploit path:** 1. Adapter returns `(price, now + 10y)` once. 2. Feed stops. 3. Five years later the oracle still serves it; collateral is priced at the last reading through any crash.
**Proof:** `E3_OracleFailOpen.t.sol::test_H4b_futureDatedAnswerIsNeverStale`:
```
[FAIL: a 1-hour window must not serve a five-year-old configuration] test_H4b_futureDatedAnswerIsNeverStale()
  price still served after 5 years of silence: 200000000000
  its stamp: 316360000     now: 158680000
```
**Recommendation:** `if (_lastUpdated > _currentTimestamp) return true;` (fail closed to backup). Optionally tolerate a small skew (e.g. 15 min) for L2 sequencer clocks.
**Invariant broken:** proposed I19 ("staleness is monotone in time").

### [LOW] H8 — rate-curve parameters are unbounded; a bad `base` overflows the index and neither the stablecoin nor the setter that would repair it can execute again
**Location:** `contracts/cap/InterestRateModel.sol:105-115` (`setLiquiditySlopes` — only `kink ≤ 1e27` is checked), `:169-172` (`setTermMultiplierSlope`, no bound), `:343-349` (`_index`), `contracts/utils/MathUtils.sol:42-78`.
**Impact:** `_index` computes `index.rayMul(1 + x + x²/2 + x³/6)` with `x = rate · Δt / year` (ray). `rayMul` reverts once `index · compounded ≥ 2²⁵⁶ − 0.5e27`, i.e. for `index ≈ 1e27` once **`x ≳ 8.8e7`** (rate × time ≥ 8.8e7 ray-years; e.g. `base = 1e37` for 30 days, `1e36` for 33 days, `≥ 3.4e38` immediately via `rayMul(rate, rate)`). From that block every `Stablecoin` deposit/redeem/mint/burn reverts (all call `updateLiquidityRate → _index`), every market borrow/repay/liquidate reverts through `mintCreditBacked`/`burnCreditBacked`, and **`setLiquiditySlopes` reverts too** because it accrues before it writes (L113). Only an upgrade recovers. Below the overflow threshold the harm is economic: at `base = 5e27` (a 100x fat-finger of `0.05e27`) floating debt grows 500 %/yr and every market is liquidatable within days.
**Likelihood:** GOVERNOR only (`ConfigureAccessControl.sol:60`). A 9-order-of-magnitude typo is implausible; a 100x one is not. Low.
**Exploit path (honest mistake):** 1. `setLiquiditySlopes({base: 1e37,...})`. 2. 30 days pass with no supply move (or the last move was > 30 days ago). 3. Everything reverts; setter reverts; upgrade required.
**Proof:** `audit/tests/scratch/E/E4_IrmBounds.t.sol`:
```
[FAIL: setLiquiditySlopes must be able to recover from a bad curve] test_H8_unboundedBaseBricksStablecoinAndSetterCannotRecover()
```
(deposit and `mintCreditBacked` both revert first; the assertion that fails is the recovery.)
**Recommendation:** Bound the curve: `base + slope0 + slope1 ≤ MAX_RATE` (e.g. `10e27` = 1,000 % APR) and `termMultiplierSlope ≤ MAX_TERM_MULT` (e.g. `9e27`, a 10x short-term premium). Make `setLiquiditySlopes` robust to a broken index: wrap the accrual so an overflow falls back to the stored index with the new rate (or provide a GUARDIAN `resetLiquidityIndex` path). Second-order: a cap on the combined rate also bounds `_premium`'s `cumulativeDebt.rayMul(rate)` and the `secondTerm`/`thirdTerm` multiplications, which currently rely on the same absence of huge values.
**Invariant broken:** none listed; the plan's H8 "permitted range ⊂ safe range" fails for `base`, `slope0`, `slope1`, `termMultiplierSlope`.

### [LOW] The averaging window weights an observation 100 % in a quiet stablecoin and 63 % in a busy one; anyone can pick the regime by spamming `updateLiquidityRate`
**Location:** `contracts/cap/InterestRateModel.sol:280-294`, `:302-305`, `:312-316`; `IInterestRateModel.sol:112-116` ("safely" permissionless).
**Impact:** `_carry` moves the average `elapsed/period` of the way to the observation *per accrual*. One accrual after `P` moves it 100 %; accruals every 12 s for `P` move it `1 − (1 − 12/P)^(P/12) ≈ 1 − e⁻¹ = 63 %`. So `averagingPeriod` is a snap interval when nobody transacts and an exponential time constant (95 % after 3P, 99 % after 5P) when anybody does — and `updateLiquidityRate` is permissionless, so the *slower* regime can be forced by anyone at gas cost. A party who benefits from the current average persisting (a lender after utilization just fell, or a borrower after it just rose, or the E-2 attacker wanting their residual discount to linger for the next borrower) can spam accruals; a party who wants the new reading to land fast cannot speed it up. The documented semantics ("an observation that has held out a full quiet period is taken at face value", L297-299) only hold in the quiet regime.
**Likelihood:** Anyone; cost is gas per block. Effect is bounded (at most 37 % of the move deferred by one window per window). Low.
**Proof:** `E4_IrmBounds.t.sol::test_EMA_weightDependsOnAccrualFrequency`:
```
[FAIL: one averaging period should weight an observation the same regardless of activity: 2132734544225241174561644 != 2500000000000000000000000]
  avg supply after one period, quiet: 2500000.0
  avg supply after one period, accrual every 12s: 2132734.5
  quiet: % of the way to the new observation: 100
  busy:  % of the way to the new observation: 63
```
**Recommendation:** Make the weighting path-independent: keep a cumulative time-weighted sum (`Σ observed_i · Δt_i`) and timestamps and define the average as the integral over the trailing window (a ring buffer or the Uniswap-style cumulative approach), or, if the EMA is kept, use `weight = 1 − exp(−elapsed/P)` so the decay is exactly exponential in both regimes and document `P` as a time constant. Second-order: an exact windowed average changes the E-2 numbers only marginally (it removes the 63 % discount in the busy regime, making E-2 slightly *worse* for lenders).
**Invariant broken:** proposed I20.

---

### [INFORMATIONAL] H4(c) — `Oracle._read` decodes any ≥ 64-byte return as `(price, timestamp)`, so an entry pointed at a raw Chainlink feed serves `roundId` as the price and `answer` as a (future) timestamp
**Location:** `contracts/cap/oracle/Oracle.sol:146-162`
**Detail:** `abi.decode(returnedData, (uint256, uint256))` ignores trailing words. An entry `{adapter: feed, payload: latestRoundData()}` — a plausible shortcut, since the adapter is stateless and the payload is free-form — decodes `(roundId, answer)`; `answer` (e.g. `2000e8 ≈ year 8306`) is a future stamp so per H4(b) the entry is never stale. Proof: `E3_OracleFailOpen.t.sol::test_H4c_rawFeedEntryDecodesRoundIdAsPriceAndIsNeverStale` → `price served (= roundId): 1`, `stamp served: 200000000000`. Real proxies return `roundId = (phase << 64) | round ≈ 1.8e19+`. Fixing H4(b) removes the "never stale" half; requiring `returnedData.length == 64` removes the other. `setSource`/`setBackup` could also dry-run the entry and refuse one that answers zero or a stamp ahead of the block.

### [INFORMATIONAL] `underwriterRate` may be zero after underwriters have committed; `maximumUnderwriterRate` and the market-multiplier band are init-only
**Location:** `InterestRateModel.sol:122-131`, `:82-88`; `BaseMarket.sol:134-138`.
**Detail:** A market owner can set the underwriter rate to 0 at any time; tranche holders remain slashable and must exit through the async queue (FIFO against `unlockedSupply`). This is documented and the underwriters chose the market, but there is no notice period; a change takes effect against the index from the current block. If `maximumUnderwriterRate` was deployed as 0 or too low, no setter exists — only an upgrade. Recommend a timelock or an event-only "pending rate" for downward moves, and a GOVERNOR setter for the maximums. WS-G: `rate_sweep.py` should treat `underwriterRate ∈ [0, max]` with no floor.

### [INFORMATIONAL] Binomial compounding error — magnitude and beneficiary
**Location:** `MathUtils.sol:42-78`, `InterestRateModel.sol:343-349`.
**Detail:** 3-term binomial vs `e^x` (relative undercharge, borrower benefits, lenders/underwriters lose):
| rate | gap | 3-term | exact | rel. error |
|---|---|---|---|---|
| 20 % | 1 day | 1.000548095353 | 1.000548095355 | 2e-12 |
| 50 % | 30 days | 1.041951892 | 1.041952014 | 1.2e-7 |
| 100 % | 365 days | 2.666663803 | 2.718281828 | −1.9 % |
Every stablecoin supply move accrues, so realistic gaps are minutes–hours and the error is negligible; only a dormant market at a very high rate sees basis points. Path-dependence (accruing in two steps vs one) is the same order. Not a finding; numbers for WS-G. Note: `rate`/`lastUpdate` semantics on `updateUnderwriterRate` and `setLiquiditySlopes` are correct — the old rate is applied over the elapsed gap before the switch (`L127-128`, `L260-263`). `updateMarketMultiplier` does *not* accrue and the multiplier applies retroactively to the whole liquidity index (`L165`), which `FloatingMarket.setMarketMultiplier` compensates for by charging premium and re-scaling `scaledDebt` first (`FloatingMarket.sol:54-65`); `FixedMarket` uses rates, not the index, so is unaffected. Verified, not broken.

### [INFORMATIONAL] Oracle chain composition — precision and configuration hazards
**Location:** `Oracle.sol:69-100`, `:129-137`.
**Detail:** (a) Precision: each leg floors at 1 unit of 1e-8 of the running product; for wstETH/stETH × stETH/ETH × ETH/USD (1.18e8 × 0.9995e8 × 3000e8) the composed result is exact to the unit and the relative error bound is `legs × 1e-8 / min(intermediate)`, negligible unless an intermediate ratio is < 1e-4. Rate feeds published at 18 decimals are truncated to 8 by the adapter before composing (rel. error ≤ 1e-8). (b) Nested chains are ignored by design (`_priceOne` reads entries only): a chain `[wstETH, stETH]` where stETH *itself* is chained `[stETH, ETH]` prices wstETH in ETH, not USD, and no check catches it — the price is wrong by ~3000x, non-zero, and passes `Registry._deployTranche`'s only check (`price()` does not revert). (c) An asset listed twice in its own chain squares its ratio. (d) `lastUpdated = min(legs)` is unused by every consumer (`Tranche.getPrice` discards it), so per-leg staleness is the whole freshness policy; a chain is never "economically stale" beyond its widest leg window. (e) `setBackup` correctly applies `_checkWindow` — a backup cannot be set with `staleness == 0` (verified). (f) Backup routing cannot be forced by an unprivileged actor: `_read` is a staticcall to a governance-chosen adapter; only feed manipulation or outage selects the backup. In production wiring `contracts/deploy/service/ConfigureAccessControl.sol` never assigns `setSource`/`setBackup`/`setChain`, so they fall through to AccessManager role 0 = ADMIN (flagged for WS-F alongside H9).
Recommend: `setChain` should reject a leg that itself has a chain (or resolve it), and reject duplicates.

### [INFORMATIONAL] Fail-closed oracle ⇒ no liquidation, no write-off, no health reading while any leg is stale
**Location:** `Tranche.sol:328-331`; `BaseMarket.sol:217-221, 245-267, 350-352, 380-386`.
**Detail:** Every `healthiness`, `maxLiquidatable`, `recoverableDebt`, `unrecoverableDebt`, `lockedValue` and `slash` reverts while `Oracle.price` reverts. Premium keeps accruing (FloatingMarket index) and cUSD keeps being minted to lenders (`_chargePremium` is reached through `borrow`/`repay`/`liquidate`, all of which revert — but `chargePremium()` itself does not touch the oracle and stays callable). This is the intended fail-closed choice, but it means H11's liveness assumption (a solvent, online liquidator) is joined by a second: a live oracle for *every* tranche asset of the market. Hand to WS-G `liquidation_cascade.py`: model oracle downtime as a liquidation pause.

### [INFORMATIONAL] `WadRayMath` half-up rounding — no accumulating bias found in WS-E scope
**Detail:** `_carry` never overshoots the observation (`(d·w + 0.5e27)/1e27 ≤ d` for `w ≤ 1e27`) so the EMA stays within `[avg, obs]`; the half-up bias is ≤ 0.5 wei per accrual toward the observation, bounded, not directional across observations. `_index`'s half-up is ≤ 0.5 wei per accrual on a 1e27-scale value (5e-22 relative over 1e6 accruals). `_premium` in `FixedMarket` rounds half-up once per charge. `_chargePremium`'s per-tranche half-up is clamped (`BaseMarket.sol:460-463`). Nothing in scope repeats a half-up on a small value in one party's favour.

---

## Formulas for modelling (for WS-G)

All rates in ray (`1e27 = 100 %`), time in seconds, `Y = 365 days = 31,536,000`.

**Rate curve** (`_nextLiquidityRate`, L329-338), `u ∈ [0, 1e27]`, `k = kink ≤ 1e27`:
```
R(u) = base + slope0 · (u / k)                          u ≤ k   (u/k := 0 when k = 0)
R(u) = base + slope0 + slope1 · (u − k) / (1e27 − k)    u > k
```
No upper bound on `base, slope0, slope1`. Spot utilization `u = creditBackedSupply / totalSupply` (`Stablecoin.sol:84-86`; note `creditBackedSupply` is *inside* `totalSupply`, and `recognizeBadDebt` lowers `u` — utilization falls exactly when lenders take a loss).

**Floating index** (`_index`, `MathUtils.calculateCompoundedInterest`), `x = R · Δt / Y` in ray:
```
I(t) = I(t₀) · (1e27 + x + x²/2 + x³/6)          (3-term; exact is I·eˣ; error ≈ −x⁴/24)
liquidityIndex(market) = I · marketMultiplier      (multiplier retroactive; FloatingMarket re-scales)
underwriterIndex(market) = same form with the market's underwriterRate, own lastUpdate
Overflow: reverts when I · (1e27 + x + x²/2 + x³/6) ≥ 2²⁵⁶ − 0.5e27  ⇒  x ≳ 8.8e7 for I ≈ 1e27
          (rate·time ≥ 8.8e7 ray-years); rayMul(rate,rate) reverts outright for rate ≥ 3.4e38
```

**EMA update** (`_accrueAverage`, `_averagingWeight`, `_carry`), state `(A_c, A_s)` averages, `(O_c, O_s)` observation standing since `t_last`, period `P ∈ [300, 86400]`:
```
on accrual at t:  w = min(1, (t − t_last)/P)
                  A ← A + (O − A) · w        (component-wise, half-up on (O−A)·w)
                  t_last ← t;  O ← live supplies (post-move)
n accruals of Δt each over total P:  A → O − (O − A₀)·(1 − Δt/P)ⁿ  →  63 % for n→∞, 100 % for n = 1
averageUtilization       = A_c / A_s
averageUtilizationAfterMint(m) = (A_c + m) / (A_s + m)
```

**Fixed premium** (`fixedRatesAfterMint`, `termMultiplier`, `FixedMarket._premium`), loan `L`, term `T ≤ T_max`, term utilization `τ = T / T_max`:
```
M_term(τ) = 1e27 + termMultiplierSlope · (1e27 − τ)      (τ ≥ 1e27 ⇒ 1e27; slope unbounded)
R_fixed   = R(averageUtilizationAfterMint(L)) · M_term(τ) · marketMultiplier
premium_liquidity   = L · T · R_fixed / Y          (charged upfront, added to debt, minted to stcUSD)
premium_underwriter = L · T · underwriterRate / Y   (flat; split across tranches by weight)
availableCredit(T)  = limit / (1 + T · (R_fixed(limit) + underwriterRate) / Y)
```

**EMA manipulation break-even** (E-2). Honest supply `S`, credit `C`, parked deposit `D` held for `P` (quiet regime; multiply the shift by 0.63 for the busy regime), opportunity rate `r`:
```
u_h = (C + L)/(S + L)          u_m = (C + L)/(S + D + L)
Δpremium = L · T · [R(u_h) − R(u_m)] / Y          (lenders' loss, attacker's gain)
cost     = r · D · P / Y  (+ gas; zero exposure while badDebt = 0)
profitable ⇔ L · T · [R(u_h) − R(u_m)] > r · D · P
With T = 30 d, P = 1 h: ratio T/P = 720; P = 1 d: 30.  Defaults: D = S = 10M, C = 8M, L = 1M ⇒ ΔR = 3.2 %/yr ⇒ Δpremium = 2,655; cost@10 % = 114 (1 h) / 2,740 (1 d).
```

**Liquidation and recoverable debt** (`_slashPerDebt`, `recoverableDebt`, `maxLiquidatable`), `b = liquidationBonus ≤ 0.1e27`, `lt ≤ 1e27`, `H* = targetHealth ≥ 1.25e27`, capital `K = Σ totalCapital` (USD, *currently 1e10 too small — see E-1*), debt `Dt`:
```
perDebt          = 1e27 + b
recoverableDebt  = K / perDebt
unrecoverable    = max(0, Dt − K/(1 + b))
health           = K · lt / Dt
maxLiquidatable  = min(Dt, K/(1+b), (H*·Dt − K·lt) / (H* − (1+b)·lt))    when Dt > K·lt
                   denominator ≥ 1.25 − 1.1 = 0.15 ray at the governance extremes
collateral released per unit repaid = (1 + b) / price    (assets)
```

**Oracle over-pricing → depositor loss** (H4). Price error factor `f = p_oracle / p_real`, real collateral `C_real`, borrow to the limit:
```
Dt_max      = ltv · f · C_real
over-borrow = ltv · C_real · (f − 1)
unhealthy on correction when f > lt / ltv          (1.6 at defaults)
unrecoverable on correction = C_real · (ltv · f − 1/(1+b))  > 0  when f > 1/(ltv·(1+b))   (1.96 at defaults)
LUNA case p_real → 0: f → ∞, the entire Dt_max is written off onto cUSD holders
```

---

## Invariants

**Broken by findings above**
- **I5** — with E-1, "liquidation is profitable at the current bonus" is satisfied by a factor of 1e10; the invariant as written does not bound over-profitability. Suggest tightening to the two-sided form in I17.
- **I8** — `variableCreditLimit ≤ debtLiquidationThreshold` still holds numerically under E-1, but both are 1e10x below what `ltv`/`lt` describe; the invariant is true and meaningless.
- **I16** — verified for the EMA path: `_accrueAverage` runs (via `mintCreditBacked`) before `fixedRatesAfterMint` is read in `FixedMarket._borrow`, and the pre-mint `availableCredit(term)` view reads the same carried average the accrual will store. Not broken.

**New invariants the code implies and the plan misses**
- **I17 (slash bound)** — for every liquidation: `assetsSlashed · p_real / 10**decimals ≤ repaid · (1 + liquidationBonus) / 1e27` (+1 wei), where `p_real` is the oracle price *in cUSD decimals*. Currently violated by 1e10 (E-1). This is the executable form of `BaseMarket.sol:337-338`.
- **I18 (scale consistency)** — `Tranche.totalCapital()` for `a` assets at price `p` equals `a · p · 10^(18 − IOracle.DECIMALS) / 10^assetDecimals`, i.e. capital and debt share cUSD's 18 decimals. Violated (E-1).
- **I19 (no reversible repricing)** — for any sequence of stablecoin `deposit`/`redeem` by one actor that nets to zero over `≤ averagingPeriod`, `premiumForBorrow(L, T)` at the end differs from its value at the start by at most what genuine third-party flow explains. Violated (E-2).
- **I20 (staleness monotone)** — if `Oracle.price(asset)` reverts `PriceError` at time `t` with no writes in between, it reverts at every `t' > t`; and an entry with `lastUpdated > block.timestamp` is treated as stale. Violated (H4-b, H4-c).
- **I21 (path-independent averaging)** — `averageSupplies()` at time `t` depends only on the piecewise-constant supply history, not on how many `updateLiquidityRate` calls occurred. Violated (E-7): 100 % vs 63 % after one period.
- **I22 (governance recoverability)** — for every setter `S` with argument domain `Dom(S)`, there exists a value in `Dom(S)` that restores a working state from any state reachable via `S`. Violated for `setLiquiditySlopes` past the overflow threshold (E-6).

---

## Appendix: gas & style

- `contracts/utils/MathUtils.sol:19-31` `calculateLinearInterest` is unused in `contracts/`.
- `ChainlinkAdapter.sol:86,90` decode `int192` into an `int256` variable; a proxy whose aggregator returns a full `int256` outside the int192 range would revert the adapter (fails closed to backup) — acceptable, but the interface should say so.
- `ChainlinkAdapter.sol:60-61` a feed with `decimals > 8` whose price is below `1e-8` USD normalises to 0 and is refused upstream (`PriceError`); collateral cheaper than 1e-8 USD cannot be listed. Document.
- `InterestRateModel.sol:331-333` with `kink == 0` the curve is `base` at `u = 0` and `base + slope0 + slope1·u` for any `u > 0` — a discontinuity at the origin. Harmless; reject `kink == 0` or document.
- `InterestRateModel.sol:251-254` on a cold system (`A_s == 0`) `averageUtilizationAfterMint(m) = m/m = 100 %`, so the first fixed borrow after deployment (or after a long dormant period following a full redemption) pays the maximum rate regardless of live liquidity. Conservative; document.
- `Oracle.sol:151` forwards all gas to the adapter; a gas-guzzling adapter can make every `totalCapital` read prohibitively expensive. Governance-controlled; consider a gas stipend.
- `test/shared/mocks/MockOracle.sol:17` declares `DECIMALS = 8` while `CapDeployer` prices at `1e18` — the mock should assert the scale it claims (root cause of E-1 escaping the suite).
- `test/unit/cap/InterestRateModel.t.sol` never tests the busy-regime EMA (every test does one `skip` then one read), which is why the 63 % behaviour is unobserved.
