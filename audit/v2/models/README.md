# Cap v2 economic models — round 2 delta (workstream G2, commit `3dad5ef`)

This directory is `audit/models/` (round 1, commit `3c45dca`) copied and updated for `3dad5ef`.
Run every script from this directory (`python3 <name>.py`); captured outputs used in
`audit/v2/findings/G2.md` are in `output/*.txt`. Standard library only.

## What changed on `3dad5ef` and what it did to the models

| Contract change | capmath | Model | Result |
|---|---|---|---|
| `WadRayMath.rayPow` (square-and-multiply, half-up `rayMul` per step, last squaring skipped) | `ray_pow` | `param_sensitivity` precision row | max error 2,376 ray-wei (2.4e-24 rel) over periods {5 m, 1 h, 1 d, 12 h} x elapsed {1 s .. 1 y}; 5-min retention^86400 = 0 exactly -> weight saturates to 1e27 |
| IRM `_averagingWeight = 1e27 - retentionPerSecond.rayPow(elapsed)`, `retentionPerSecond = 1e27 - 1e27/period` | `averaging_weight` (exponential), `retention_per_second`; round-1 linear kept as `averaging_weight_v1`; `UtilizationAverage(t0, period, weight=)` | `ema_manipulation` | weight(P) = 0.632 not 1; saving is concave in D so at D = 1x S the $ saved falls 8 % (1-day period); break-even D unchanged ($0.1M grid minimum) in every cell. **Round-1 conclusion stands.** |
| `PremiumVesting._weight` same form, `VESTING_PERIOD = 12 h` constant (setter gone), opt-in `staked` denominator, zero-staked freeze | `vesting_weight`, `vested`, `VESTING_PERIOD` | `run_dynamics` part C (new), `param_sensitivity` | JIT take for matched capital: 19.7 % @ 6 h, 31.6 % @ 12 h, 43.2 % @ 24 h, 49.1 % @ 48 h of a front-loaded fixed premium; never below time-pro-rata inside a 7 d or 30 d term |
| `BaseMarket._chargePremium`: liquidity premium -> `Stablecoin.fundCreditBacked` -> vested to opted-in cUSD holders | — | `reserve_decay` section 5 (new) | R/S path identical for every opt-in fraction (rho = 0); if vested premium is redeemed the day it vests the < 5 % clock moves 4.5 y -> 1.1 y; non-opted-in holders lose 22.6 % of supply share per year at u = 80 % |
| `Stablecoin.invest/recall` to an Aera `reserveVault` (KEEPER, no cap, invisible to `unlockedSupply`) | — | **`reserve_investment.py` (new)** | 1-day recall latency: phi > 0.75 reverts a 5 %/day redemption day (phi > 0.50 at u = 90 %); Aera loss lands 100 % on the last ell*phi*R of redeemers as a revert; P(revert in 7 d) < 1 % needs phi <= 0.33 at 1 %/day, 0 at >= 2 %/day |
| nothing else in the modelled formulas | — | `haircut_curve`, `liquidation_cascade`, `rate_sweep`, `solvency_waterfall` | outputs **byte-identical** to round 1 (`diff` = 0 lines) |

`param_sensitivity` headline changed 13/18 -> **12/19**: the `vestingPeriod` row (was YES) is now the fixed
`VESTING_PERIOD` constant (no), and a `retentionPerSecond` precision row (no) was added; `averagingPeriod`
is now GOVERNOR (was ADMIN-by-omission) but the economic overlap is unchanged.

Modelling assumptions added this round: opt-in fraction f applies to the depositor-held circulating cUSD
(S - C); rho is the fraction of vested premium redeemed at par the day it vests; the invested-reserve
Monte Carlo uses the round-1 run-dynamics daily request `w0` with lognormal noise (sigma = 100 %), 1 %/day
fresh repayment, keeper recall of the whole invested slice `tau` after balance < 1.5x mean demand, 8,000
paths per cell.

---

# Round-1 README (unchanged below; `capmath` table gains `ray_pow`, `averaging_weight` (exp), `averaging_weight_v1`, `vesting_weight`, `vested`)

Runnable numerical models of the Cap v2 (`cap-network`) economics. Each script is standalone
Python 3 (standard library only; numpy is optional and unused), imports the shared
`capmath.py`, and prints its **critical threshold** at the end under `=== HEADLINE ===`.

```
cd audit/models
python3 reserve_decay.py
python3 solvency_waterfall.py
python3 haircut_curve.py
python3 liquidation_cascade.py      # ~20 s (Monte Carlo)
python3 rate_sweep.py
python3 run_dynamics.py
python3 ema_manipulation.py
python3 param_sensitivity.py
```

Captured output from the run used in `audit/findings/G.md` is in `output/*.txt`.

## `capmath.py` — the arithmetic, once

Every formula that mirrors Solidity is implemented exactly once, in Python ints with `1e27` as
one ray, reproducing the contract's rounding and `uint256` revert behaviour:

| capmath | contract |
|---|---|
| `rayMul` / `rayDiv` (half-up, overflow revert) | `WadRayMath.sol` |
| `mulDiv(a,b,c, FLOOR/CEIL)` | OZ `Math.mulDiv` |
| `compounded_interest(rate, exp)` (3-term binomial) | `MathUtils.calculateCompoundedInterest` |
| `next_liquidity_rate`, `term_multiplier`, `averaging_weight`, `carry`, `UtilizationAverage` | `InterestRateModel.sol` |
| `StablecoinState._convertToAssets/_convertToShares/_onWithdraw/unlockedSupply` | `Stablecoin.sol` L193-285 |
| `healthiness`, `recoverable_debt`, `unrecoverable_debt`, `max_liquidatable`, `locked_value` | `BaseMarket.sol` |
| `fixed_premium`, `principal_within` | `FixedMarket.sol` |
| `tranche_slash` | `Tranche.slash` |

Defaults come from `contracts/deploy/service/DeployInfra.sol` (IRM `1e27, 2e27, 1e27, 0.02e27,
1 hours`; Registry `lt 0.8 / buffer 0.1 / targetHealth 1.25`) and `test/shared/CapDeployer.sol`
(ltv 0.5, slopes 5%/5%/10%/kink 80%, underwriter rate 20%, weights 95/5, max term 30 d).
**`DeployInfra` never sets liquidity slopes**, so a production deploy starts at a 0% liquidity
rate until governance calls `setLiquiditySlopes`; the CapDeployer curve is used as "intended".

## Global assumptions

* cUSD supply $100M (results in utilization are scale-free; dollar figures scale linearly).
* Collateral is ETH-like: one correlated asset class, price $2000, annualised vol 40–300%.
* Tranche capital is split in the same proportion as the premium weights (95/5). This is an
  assumption — weights govern premium only; capital is whatever underwriters posted.
* Where the model needs a behavioural parameter it is stated in the script docstring
  (redemption demand 5%/day, opportunity cost 5%/yr, book depth 5,000 ETH per 1% impact, borrower
  default probability 1–10%/yr). Change them at the top of each file.

## Models and headline thresholds

**`reserve_decay.py` (H1).** Premium is minted credit-backed with no reserve added, so the
reserve ratio `(S − C − badDebt)/S` decays as unpaid premium accrues. At the default 80%
utilization and 30% carry (10% liquidity + 20% underwriter), reserve falls from 20% to 15.5% in a
year and first breaches a 5%-of-supply/day redemption assumption after **4.5 years**; at 90%
utilization, 2.1 years. Only initial utilization ≥ 92.9% breaches it within a year. A $10M
30-day fixed borrow mints ~$250k premium instantly. The ratio stabilises only if borrowers repay
≥ (1 − u) of accruing premium with *fresh* underlying, or 100% of it with existing cUSD. H1 is a
slow solvency clock, not a cliff.

**`solvency_waterfall.py`.** With the credit line fully drawn (debt = 0.5·K), health < 1 at a
**37.5%** correlated price drop, and cUSD holders first take a loss (`unrecoverableDebt > 0`) at
**49.0%** if no liquidation lands in between — the cushion is `1 − (1+bonus)·lt` = 18.4% of price.
The first liquidation at health = 1 clears **58% of the debt** (to reach targetHealth 1.25),
which wipes and permanently **kills** a 5% junior tranche in every scenario and touches the senior
in the same call. `healthiness()` *leads* unrecoverable debt at defaults but **lags** whenever
`lt > 1/(1+bonus) = 0.9804`, which `setLt` permits.

**`haircut_curve.py` (H6/I10/I11).** Bit-exact replica. Across 7,020 split cases (n ≤ 1000),
decimals 6/8/18, shortfall 0–99.99%: **0 wei** over-payment from splitting, **0 wei** round-trip
gain, monotone `previewRedeem`, `unlockedSupply ≤ balance` preserved, and depositing-at-par to
improve an exit never gains. The NatSpec claims survive; I10 and I11 hold.

**`liquidation_cascade.py` (H11).** With a rational liquidator who clips each call so impact
stays under the bonus, the system **clears** on every path up to 300% vol at every
bonus > 0 / lt / targetHealth tested. Loss comes from *liveness*: offline liquidator gives
P(loss in 30 d) = 4% at 100% vol and 12% at 150% vol; at lt 0.95 (3.1% cushion) a 24-hour check
interval already loses on 5–15% of paths. **Bonus 0% is permitted and makes every liquidation
unprofitable** (identical to offline). The liquidator must hold ~$30M cUSD at par to restore a
$50M market from health 1.0 (58% of debt at TH 1.25; 73% at 1.5).

**`rate_sweep.py` (H8).** Lender yield rises with utilization (5% → 20%, ×2 with the
multiplier); the underwriter rate is flat, set by the **market owner** (the borrowing side), has
floor 0, and responds to nothing. Protocol take: **none exists**. Underwriting is negative-EV
whenever `underwriterRate < (1+bonus)·(p_default + 0.58·p_volLiq)`: **2.04%** at 2%/yr default
risk, 5.10% at 5%. At full draw 71% of tranche capital is locked, so the rational exit is a queue
that settles only as debt is repaid.

**`run_dynamics.py` (H5).** `burnCreditBacked` lowers `totalSupply` and `creditBackedSupply`
together, so repayment funded by cUSD bought from holders **never raises `unlockedSupply`**; only
fresh underlying (deposit-then-repay) settles the queue. With 1%/day fresh-funded repayment,
orderly redemption (wait ≤ 7 d) breaks at daily requests ≥ **1.12%** of supply. The convex
haircut **does** remove the first-mover advantage for *recognised* bad debt (payout per share is
monotone increasing along the queue: 0.8157 → 0.8910). It does **not** cover unrecognised bad
debt: exits before the discretionary `writeOff` are paid par, and each $1 out shifts
`shortfall/supply` of loss onto survivors ($2M on a 10% shortfall with 20% of supply exiting).
Also: a borrower repaying with cUSD bought from a holder is a haircut-free exit for that holder
(backing 0.900 → 0.889 on a $10M repayment).

**`ema_manipulation.py` (H10).** Exact `_accrueAverage`/`_carry` replica. At 90% utilization a
$100M par deposit held for one full averaging period cuts a $10M 30-day fixed premium from
$127,024 to $65,558 — **$61k saved for $13.7k of opportunity cost at the 1-day maximum period,
and $68 at the 5-minute minimum**. Break-even capital is < 0.1× supply at every period for
loans ≥ $1M at 90% utilization. The band bounds the attack's *duration*, not its profitability.
`termMultiplier` is 1 at the maximum term, so it does not touch the attack.

**`param_sensitivity.py` (H8).** **13 of 18** governance-settable parameters have a permitted
range overlapping an unsafe one. Accounting-breaking overlaps: `lt ∈ (0.9804, 1]` with bonus 2%
(health lags unrecoverable debt); unbounded liquidity slopes (≥ 17,207%/yr makes a fully-drawn
market liquidatable within a day; > 3.4e11 ray reverts `_index()` and bricks floating markets);
`Registry.initialize` accepting `lt/buffer/targetHealth` with no validation (`lt ≤ buffer`
reverts `lockedValue`, bricking every tranche redemption; `TH < (1+b)·lt` reverts
`maxLiquidatable`, bricking liquidation); `liquidationBonus = 0`; `vestingPeriod = 1 s`.
