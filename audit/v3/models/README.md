# Cap v2 economic models — round 3 (workstream G, HEAD `a843c1d`)

Runnable numerical models of the Cap v2 (`cap-network`) economics, re-derived from the HEAD
contracts. Every formula that mirrors Solidity lives once in `capmath.py` (Python ints, `1e27` =
one ray, same rounding and `uint256` revert behaviour as the EVM; each function's docstring cites
`file.sol:Lx-Ly`). Every other script is standalone, prints tables to stdout, and ends with the
critical threshold under `=== HEADLINE ===`. No plots.

```
cd /Users/weso/cap-contracts
PY=/private/tmp/claude-501/-Users-weso-cap-contracts/3c26655f-4698-4fc0-9c28-9e8265b1e175/scratchpad/tools/venv/bin/python3
$PY audit/v3/models/solvency_waterfall.py          # ~1 s (numpy for the correlated section)
$PY audit/v3/models/coverage_dynamics.py
$PY audit/v3/models/liquidation_cascade.py         # ~1 s
$PY audit/v3/models/rate_sweep.py
$PY audit/v3/models/run_dynamics.py
$PY audit/v3/models/param_sensitivity.py
$PY audit/v3/models/ema_manipulation.py
$PY audit/v3/models/premium_accrual_insolvent.py
```

Only `solvency_waterfall.py` imports numpy; everything else is standard library. Captured stdout
of the run quoted in `audit/v3/findings/G.md` is in `output/<script>.txt`. (`wadray_check.py` /
`output/wadray_check.txt` in this directory belong to workstream A.)

## What changed at HEAD and how the models follow it

| HEAD change | capmath | Used by |
|---|---|---|
| Floating multiplier is an **exponent**: `local *= (globalNow/lastGlobal) ^ m` via `rayPowRay` (`FloatingMarket._growIndex` L195-202; `WadRayMath` L96-167) | `ray_pow`, `ray_ln`, `ray_exp`, `ray_pow_ray`, `grow_index` | `rate_sweep` |
| Fixed multiplier is still **linear** on the liquidity leg (`FixedMarket._ratesStillToMint` L262) | `fixed_liquidity_rate` | `rate_sweep` |
| Fixed `_borrowPremium` is incremental in the **global** `unsmoothedCredit` (L337-351) | `borrow_premium` | `rate_sweep` §6 (P6) |
| `averageUtilizationAfterMint` adds unabsorbed **credit** to both sides, reserve-only moves not (IRM L227-239) | `UtilizationAverage.average_utilization_after_mint(now, live_credit, mint)`, `unsmoothed_credit` | `ema_manipulation`, `rate_sweep` |
| `Stablecoin.unlockedSupply` capped by the **on-hand** balance (L184-192); `recognizeBadDebtInReserve` leaves `creditBackedSupply` alone (L152-156) | `StablecoinState(..., invested=)`, `recognize_in_reserve/credit` | `run_dynamics` |
| `Tranche.slash` reports delivered value, floor-to-zero passes on, clamp, kill latch (L71-95) | `TrancheState.slash`, `liquidate` (waterfall) | `solvency_waterfall`, `coverage_dynamics`, `liquidation_cascade` |
| `lockedValue` **ceils** (L277); `Tranche.unlockedSupply` ceils twice + OZ share quote (L163-174) | `locked_value`, `TrancheState.unlocked_supply` | `coverage_dynamics`, `solvency_waterfall`, `rate_sweep` |
| `_earnsPremium` (staked > 0 and capital > 0) and the junior→senior→stablecoin fallback (L435-485) | `charge_underwriter_premium`, `TrancheState.earns_premium` | `premium_accrual_insolvent` |
| Underwriter book = idle + token-denominated `debt[tranche]` marked only on allocate/deallocate/report (L187-203, L243-245) | modelled inline | `coverage_dynamics` |
| `PremiumVesting.VESTING_PERIOD` = 12 h constant | `vesting_weight`, `vested` | (available) |
| `Registry.initialize` now validates `lt <= 1`, `lt > buffer`, `targetHealth >= 1.25` (L106-107) | — | `param_sensitivity` (round-1 overlap closed) |

## Parameters and global assumptions

* Deploy defaults (`script/deploy/service/DeployInfra.sol` L88-93, L168-170): lt 0.8, buffer 0.1,
  targetHealth 1.25, liquidation bonus 2%, averaging 1 h, multiplier band [1, 2], max underwriter
  rate 100%/yr. **No deploy script sets liquidity slopes, a term-multiplier slope, an underwriter
  rate, ltv, term limits or grace.** Production therefore starts at a 0% liquidity rate. The
  values marked HARNESS in `capmath.DEFAULTS` are `test/shared/CapDeployer.sol` L113-133 (ltv 0.5,
  base 5% / slope0 5% / slope1 10% / kink 80% — applied only when `applyLiquiditySlopes` is true —
  underwriter rate 20%, weights 95/5, max term 30 d, min 1 d, grace 1 d). Where a model depends on
  the curve it says so and `rate_sweep` sweeps a steeper alternative (2/8/50/kink 90).
* cUSD supply $100M; one market with K0 = $100M of ETH-like collateral at $2000; full draw
  D = ltv·K0 = $50M; tranche capital split like the premium weights (an assumption: weights govern
  premium only). Results in utilization / drawdown are scale-free.
* There is **no restaking code** in `contracts/`; correlation enters `solvency_waterfall` only
  through shared collateral assets (one-factor Gaussian returns) and the shared cUSD write-off.
* Behavioural inputs are stated at the top of each script (opportunity cost 5%/yr, stcUSD yield
  8%/yr, gas, book depth k = 0.1–2% per $1M sold, default probabilities 1–10%/yr, keeper /
  liquidator / guardian latencies 1 h–24 h). Change them there.

## One line per script (headline numbers; all reproducible from `output/`)

* **`solvency_waterfall.py`** — full draw at ltv 0.5: a 5% junior is wiped and killed by the first full-default liquidation at any drawdown; cUSD holders lose at d ≥ 49.0% (f = 1) / 74.5% (f = 0.5); at ltv 0.7 the threshold is 28.6% and at lt 0.9 the liquidatable point is 22.2% — 6.4 points between "can liquidate" and "already insolvent". Dust rule costs ≤ price/10^dec per tranche ($6e-4 for WBTC). Silo'd protection: at ρ = 0 and 2%/period per-market loss, system loss is more likely than not from N ≥ 35 markets; silo loss is up to 29× the pooled loss at ltv 0.7.
* **`coverage_dynamics.py`** — `healthiness()` leads: at −3%/h it crosses 1 at hour 16, senior `unlockedSupply` hits 0 at hour 12, cUSD loss at hour 23 with no liquidator (7-hour window; a 24-hourly liquidator loses $2.8M). cUSD loss needs ≥ 19.2%/h (hourly liquidator), 5.45%/h (6 h), 2.76%/h (24 h). The Underwriter book lags each slash by 0/2/8 h at report cadence 1/6/24 h and never reflects price; `backing()` reports 100% until writeOff.
* **`liquidation_cascade.py`** — at impact 0.5%/$1M an hourly liquidator clears in 6 clips with 20.9% oracle impact; critical impact k* = 0.77%/$1M (L = 1 h), 0.55 (6 h), 0 (24 h: the path is already insolvent); at lt 0.9 k* = 0.39. Bonus 0 = offline. Fixed (P7): at the harness 20% underwriter rate a fully-drawn fixed market goes unhealthy from accrual alone after 28.8 rolls (865 d) and 12.5 more (374 d) to cUSD loss; every day past expiry without a keeper roll is free credit ($8,219/day per $10M at 30%).
* **`rate_sweep.py`** — floating pays `(1+r)^m − 1` (exponent), fixed `m·r` (linear): +9.18 pts at u = 1, m = 2; floating > fixed rolled monthly at every (u, m) by 0.5–2.6 pts → migration to the EMA-priced fixed market. Protocol take: none exists. P8: borrow-to-stake is a money pump while staked/S < u/(1 + uw/r) = 26.7% at u = 0.8 (harness rates). P6: a $10M 30 d fixed draw after a same-block $50M floating borrow is overcharged $17,123 (15.2% of its own premium). Underwriting negative-EV below 2.04% at 2%/yr default risk; the senior can exit 30% of capital until d = 28.6%, before liquidation is possible at 37.5%.
* **`run_dynamics.py`** — instant capacity (1−u)(1−φ) of supply (5% at u 0.8 with 75% of the reserve in Aera); an unrecognised Aera loss makes par exit dominant above ℓ*/S = 0.044% of supply at P(recognition) = 50%/day, shifting ℓ/(S(1−f)) onto stayers; after recognition the quadratic curve pays the first exiter backing² and later exiters more — "exit repairs the peg" holds.
* **`param_sensitivity.py`** — 12 of 18 parameters overlap an unsafe range: lt ∈ (0.9804, 1] (I38/P13); slopes unbounded (≥ 17,207%/yr liquidates a full market within a day, > 3.40e11 ray reverts `_index`); buffer ≥ 0.30 freezes every tranche exit (GUARDIAN, one call); TH ≥ 2.66 makes the first liquidation ≥ 90% of debt; termMultiplierSlope ≥ 2516 DoSes 1-day terms; grace init-only; `Registry.initialize` is now validated.
* **`ema_manipulation.py`** — M-2 regression: a flash deposit now yields 0 bp (HEAD rule), but $100M parked one 1 h period at u = 90% cuts a $10M 30 d premium $127,024 → $70,752 (685 bp), $56,271 saved for $591 of carry; break-even D = $0.1M at every permitted period; at the 5-minute minimum the carry is $68.
* **`premium_accrual_insolvent.py`** — with $20M unrecoverable on a $50M floating debt, every day without writeOff mints ~$39k of unbacked cUSD: +$1.17M (+5.9%) at 30 d, +$16.4M (+82%) at 365 d, 71% of it to the senior tranche about to be slashed, 29% to stcUSD; with both tranches empty all of it vests on the stablecoin.
