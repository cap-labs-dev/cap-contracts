# Workstream G — Economic modelling (Python, `audit/models/`)

Eight runnable models, one shared exact-arithmetic module (`capmath.py`), all outputs pasted at
the bottom of this file verbatim from `python3 audit/models/<name>.py` (also in
`audit/models/output/*.txt`). Every number below is from those runs. Assumptions are in each
script's docstring and in `audit/models/README.md`.

Severity counts: **Medium 2, Low 6, Informational 4.**

---

### [MEDIUM] Time-weighted utilization is cheaply depressible across the entire permitted averagingPeriod band; fixed-rate borrowers can halve their liquidity premium
**Location:** contracts/cap/InterestRateModel.sol (`_accrueAverage`, `_averagingWeight`, `_carry`, `averageUtilizationAfterMint`, `fixedRatesAfterMint`); contracts/cap/market/FixedMarket.sol (`_chargePremiumForTerm`, `_ratesStillToMint`); contracts/cap/Stablecoin.sol (`previewDeposit` at par, no fee)
**Impact:** The liquidity premium on a fixed loan is priced off `averageUtilizationAfterMint`, an EMA of `(creditBackedSupply, totalSupply)` with a window banded to [5 min, 1 day]. A borrower who parks capital in `Stablecoin` for one window (par mint, par redeem, no fee) lowers the average, takes a max-term loan at the depressed rate, and withdraws. At u = 90%, S = $100M: a $10M 30-day loan's liquidity premium falls from $127,024 to $65,558 (−48%). Lenders (`stakedStablecoin`) receive that much less; the borrower keeps it. Because the average is global, the same deposit discounts every fixed borrow taken in that window by any borrower.
**Likelihood:** Requires the BORROWER role on a fixed market (permissioned), and capital D for time t. Cost = D·r_alt·t + gas. At the 1-day maximum window with D = $100M and r_alt = 5%: $13,719 → 4.5× return on a $10M loan. At the 5-minute minimum: $68. Break-even D is < 0.1× supply at every window for L ≥ $1M at u = 90% (table in `ema_manipulation.py` output). The deposit is only stuck if a redemption queue already stands (then `instantUnlockedSupply` is consumed FIFO), which is the one real cost.
**Exploit path:**
1. State: S = $100M, C = $90M (u = 90%), EMA quiet (averages = live). Attacker is a fixed-market borrower with $100M of the underlying.
2. `Stablecoin.deposit($100M)` — mints at par; `_deposit → updateLiquidityRate → _accrueAverage` records `observedSupply = $200M`.
3. Wait `averagingPeriod` (weight → 1e27). Nobody else needs to act; any other supply movement re-folds with the attacker's observation standing.
4. `FixedMarket.borrow($10M, maximumTermLimit)`. `_borrow` mints $10M → `_accrueAverage` folds [0, t] with (C, S+D); `_chargePremiumForTerm` prices at `averageUtilizationAfterMint($10M)` = 51.8% instead of 90.9%; liquidity rate 8.2% instead of 15.5%.
5. `Stablecoin.redeem($100M)` at par (unlockedSupply rose by D at step 2).
6. Net: premium saved $61,466; cost $13,719 (1-day window) or $68 (5-min window). Same trade works at u = 80% for loans ≥ $10M (saves $31k at the 5-min window).
**Proof:** `audit/models/ema_manipulation.py` — exact integer replica of `_accrueAverage`/`_carry`/`_averagingWeight`; break-even (D, t) table for L ∈ {$1M, $10M, $50M} × period ∈ {5m … 24h}; headline "At the MAXIMUM averaging period (1 day) … saves $61466 at a cost of $13719".
**Recommendation:** The EMA cannot defend a par, fee-free, instantly-redeemable deposit. Either (a) charge the fixed premium at `max(spot utilization after mint, average)`, so a depressed average never prices below spot; or (b) exclude supply that has been in the contract for less than one window from the averaged supply (age-weighted deposits); or (c) introduce a redemption delay or fee on `Stablecoin` deposits redeemed within a window. Option (a) is the smallest change and removes the profit entirely (the honest rate is the spot-after-mint rate the model uses as the baseline). Second-order: (a) makes fixed rates spikier during genuine short-lived utilization jumps, which is what the EMA was meant to smooth.
**Invariant broken:** none listed; implied new invariant "no permissionless flow can price a fixed premium below the spot-after-mint liquidity rate" (proposed as I17 below).

---

### [MEDIUM] The haircut curve socialises only *recognised* bad debt; `unrecoverableDebt()` is public and `writeOff` is discretionary, so informed holders exit at par before recognition and leave the shortfall to whoever stays
**Location:** contracts/cap/Stablecoin.sol (`_convertToAssets` uses `badDebt` only; `previewRedeem` at par while `badDebt == 0`); contracts/cap/market/BaseMarket.sol (`unrecoverableDebt` view, `_writeOff` GUARDIAN-gated); contracts/cap/market/FloatingMarket.sol / FixedMarket.sol (`writeOff` restricted)
**Impact:** The curve's documented purpose is to make "exiting first the worst time to exit". The model confirms it does exactly that for recognised bad debt (payout/share rises monotonically along the queue, 0.8157 → 0.8910 in the 10%-shortfall run). But between the moment `unrecoverableDebt() > 0` and the GUARDIAN's `writeOff`, `badDebt == 0`, `_convertToAssets` returns par, and every redemption is paid in full from the reserve. With a 10% shortfall and 2%/day exits, 20% of supply leaves at par over 14 days and transfers **$2.0M** of loss onto the remaining 80% (their whole-supply payout falls from 0.900 to 0.875 per share). The reserve is finite (20% of supply here), so the transfer is capped at `reserve × shortfall/supply`, but that cap is the *entire* reserve.
**Likelihood:** Preconditions: an unrecoverable slice exists (collateral jump > cushion, or a rolled defaulted loan per H3) and the GUARDIAN has not yet written it off. `unrecoverableDebt()` is a public view; a bot watching it needs no role and no capital beyond its own cUSD. Cost: gas. The GUARDIAN action is manual and bounded only from above, so the lag is whatever operations make it.
**Exploit path:**
1. State: S = $100M, reserve $20M, one market with $10M of `unrecoverableDebt()` after a price jump (or an `extendAdmin`-rolled loan that will never repay). `badDebt == 0`.
2. Holder H (any address, $5M cUSD) reads `market.unrecoverableDebt() > 0`.
3. `Stablecoin.redeem($5M)` — `previewRedeem` = par, paid from the reserve.
4. GUARDIAN calls `writeOff` → `badDebt = $10M`, `creditBackedSupply −= $10M`.
5. Remaining holders' backing ratio = ($95M − $10M)/$95M = 0.8947 instead of 0.90; H avoided a $500k haircut, entirely borne by the survivors.
**Proof:** `audit/models/run_dynamics.py` part C ("Recognition lag") — table of t_w vs exits-at-par vs loss transferred; part B shows the curve is monotone once badDebt is set (the design claim holds *after* recognition).
**Recommendation:** Make recognition automatic or at least make the redemption side see it: `Stablecoin._convertToAssets` could subtract a registry-aggregated `Σ market.unrecoverableDebt()` alongside `badDebt` (a "provisional shortfall"), so the haircut applies from the block the loss becomes visible. Second-order: `unrecoverableDebt` is oracle-driven and can flicker; a provisional haircut that later reverses over-charges the redeemers who exited during the flicker (they cannot be made whole). A cheaper mitigation is a keeper-callable `writeOff` bounded exactly as today so the lag is seconds rather than a governance cycle.
**Invariant broken:** the spirit of I5 (the system reports "covered" while a loss is already crystallised) and the design claim in `Stablecoin.sol` NatSpec ("exiting first is the worst time to exit") for the interval before recognition.

---

### [LOW] `setLt` permits `lt > 1/(1+liquidationBonus)`, at which `healthiness() >= 1` while `unrecoverableDebt() > 0` — every health gate passes on a market already exposing cUSD holders
**Location:** contracts/cap/market/BaseMarket.sol (`setLt` L79-88: only `lt <= 1e27 && lt > buffer`; `healthiness`, `recoverableDebt`, `_setTranches`, `FixedMarket.extend`/`_borrow` health checks)
**Impact:** Real protection is `recoverableDebt/totalDebt = K/((1+b)·debt)`; health is `K·lt/debt`. They cross at `lt = 1/(1+b)` = 0.9804 at the default 2% bonus (0.9091 at 10%). Above it, a market can have `unrecoverableDebt > 0` (cUSD holders already short) while `healthiness() >= 1e27`, so `borrow`, `extend`, `setTranches` all succeed and `liquidate` reverts `Healthy()`. I5 is broken: neither branch of the disjunction holds. The `maxLiquidatable` NatSpec proves its own denominator stays positive (0.15 ray of slack) but does not consider this crossing.
**Likelihood:** Requires GUARDIAN to set `lt ∈ (0.9804, 1]` (or bonus and lt to be raised independently by GOVERNOR/GUARDIAN to a pair with `(1+b)·lt > 1`). No attacker needed; misconfiguration.
**Exploit path:** 1. GUARDIAN `setLt(0.99e27)`. 2. Debt $50M, collateral falls to $50.5M: `recoverableDebt` = $49.5M < debt → `unrecoverableDebt` = $0.5M; `healthiness` = 50.5·0.99/50 = 1.0 → not liquidatable, not "unhealthy", `writeOff` is the only remaining action. 3. Every further price tick adds to the shortfall with no liquidation possible until health < 1, by which point recoverable is already 1% short.
**Proof:** `audit/models/solvency_waterfall.py` section 4 (lt sweep: "LAGS: unrec>0 while healthiness>=1" for lt ≥ 0.9804); `param_sensitivity.py` "healthiness lag threshold".
**Recommendation:** In `setLt` and `_setLiquidationBonus`, require `rayMul(lt, 1e27 + liquidationBonus) <= 1e27` (bonus is global, so `setLiquidationBonus` must check every market's `lt`, or the check must live in `setLt` with a bonus cap of `1/lt_max − 1`). Add the same check to `Registry.initialize`.
**Invariant broken:** I5. Proposed new invariant: `lt · (1 + liquidationBonus) <= 1e27` for every market.

---

### [LOW] `Registry.initialize` accepts `lt`/`buffer`/`targetHealth` with no validation; `BaseMarket.__BaseMarket_init` copies them unchecked, so a mis-deployed registry bricks tranche redemption (`lockedValue` divides by zero) or liquidation (`maxLiquidatable` underflows) on every market it creates
**Location:** contracts/cap/Registry.sol L101-124 (`initialize`); contracts/cap/market/BaseMarket.sol L47-58 (`__BaseMarket_init`), `lockedValue` (`rayDiv(debt, lt − buffer)`), `maxLiquidatable` (`targetHealth − perDebt·lt`)
**Impact:** With `lt <= buffer`, `lt − buffer` underflows (revert) or is zero (`rayDiv` reverts on `b == 0`), so `Tranche.unlockedSupply`, `maxRedeem`, `claimableRedeemRequest` and every queued claim revert — no underwriter can exit. With `targetHealth < (1+bonus)·lt`, `maxLiquidatable` underflows and every `liquidate` reverts. Registry has no setter for these three, so repair means each market's GUARDIAN calling `setLt`/`setBuffer` in the right order (possible) — but every market created before the fix ships bricked.
**Likelihood:** Deployment-time only; `DeployInfra` hardcodes 0.8/0.1/1.25 which is fine. Low.
**Exploit path:** n/a (misconfiguration). 1. Registry initialised with `buffer = 0.8e27, lt = 0.8e27`. 2. `createMarket` → `lockedValue` reverts for any debt → `Tranche.unlockedSupply()` reverts → tranche depositors cannot queue-claim.
**Proof:** `audit/models/param_sensitivity.py` rows "Registry lt/buffer/targetHealth", "buffer", "targetHealth".
**Recommendation:** Apply the setter checks in `Registry.initialize` (`buffer < lt <= 1e27`, `targetHealth >= 1.25e27`, and the `(1+bonus)·lt <= 1e27` check above), and add Registry setters so the defaults can be corrected without redeploying.
**Invariant broken:** I7/I8 are unevaluable (revert) in this state.

---

### [LOW] Liquidity slopes are unbounded; a governance value above 3.4e11 ray reverts `_index()` and bricks every floating market, and values far below that make any drawn market liquidatable within a block
**Location:** contracts/cap/InterestRateModel.sol (`setLiquiditySlopes` — only `kink <= 1e27` is checked), `_index`, contracts/utils/MathUtils.sol (`calculateCompoundedInterest`: `rate.rayMul(rate)`)
**Impact:** `rayMul(rate, rate)` reverts when `rate > 3.403e11 ray` (3.4e13 %/yr). Above that, `liquidityIndex` → `_index` reverts, so `FloatingMarket.totalDebt`, `borrow`, `repay`, `liquidate`, `writeOff`, `healthiness` all revert until the slopes are lowered (which `setLiquiditySlopes` can do, since `_updateLiquidityRate` computes `_index(liquidityData)` first — it would revert too; the only exit is an upgrade). Below that, a rate ≥ 17,207%/yr moves a market drawn to ltv (health 1.6) to health 1.0 within one day; ≥ 1.26e8 %/yr within one 12-second block. No attacker is needed; a fat-finger `8e27` instead of `0.08e27` (which the kink check exists to catch on the kink side) yields 800%/yr and pushes every fixed borrow's whole-term premium to 66% of principal.
**Likelihood:** GOVERNOR misconfiguration. Low.
**Exploit path:** n/a. 1. GOVERNOR `setLiquiditySlopes({base: 1e40, …})`. 2. `_updateLiquidityRate` stores `ratePerYear = 1e40`. 3. Next block, `_index` → `calculateCompoundedInterest` → `rayMul(1e40, 1e40)` reverts. 4. All floating-market entry points revert; `setLiquiditySlopes` also reverts (it calls `_updateLiquidityRate` → `_index`). Recovery requires an implementation upgrade.
**Proof:** `audit/models/param_sensitivity.py` "base / slope0 / slope1" row; "compoundedInterest revert thresholds".
**Recommendation:** Bound `base + slope0 + slope1 <= MAX_RATE` (e.g. 10e27 = 1000%/yr) in `setLiquiditySlopes`, and bound `termMultiplierSlope` similarly. Note the check must be on the *sum* because `_nextLiquidityRate` is `base + slope0 + slope1` at u = 1.
**Invariant broken:** I16 (accrual before action) becomes unsatisfiable rather than violated.

---

### [LOW] `liquidationBonus = 0` is permitted and makes every liquidation strictly unprofitable, which is indistinguishable from an offline liquidator: P(cUSD loss in 30 d) = 4% at 100% vol, 12% at 150% vol on a fully-drawn ETH market
**Location:** contracts/cap/InterestRateModel.sol (`_setLiquidationBonus`: only `<= 0.1e27`); contracts/cap/market/BaseMarket.sol (`_slashPerDebt`, `_liquidate` LIQUIDATOR-only)
**Impact:** The liquidator burns cUSD at par and receives `(1+bonus)` of collateral at the oracle price. At bonus 0 the best case is break-even before impact and a loss after any slippage, so a rational liquidator never acts. With the only liquidator idle, `unrecoverableDebt` accrues on any path that crosses the 18.4% cushion between health = 1 and unrecoverable; the model gives P(loss) 4% / 12% over 30 days at 100% / 150% vol and an average shortfall of $7–9M on a $50M market. Even at bonus 2%, a liquidator facing a $29M first clip must split it into ~$20M clips at the stated depth to stay profitable, and needs ~$30M of cUSD at par (58% of debt) to restore health 1.0 → 1.25.
**Likelihood:** GOVERNOR sets 0 (permitted, documented as a valid value in `_setLiquidationBonus`'s band), or the single LIQUIDATOR role-holder is offline/undercapitalised (H11). Low.
**Exploit path:** n/a (liveness). 1. bonus = 0 or liquidator offline. 2. ETH −40% in a day: health 0.96, `maxLiquidatable` $33M, nobody acts. 3. ETH −50%: `unrecoverableDebt` $1M, growing with each further tick and with premium accrual; GUARDIAN `writeOff` socialises it to cUSD.
**Proof:** `audit/models/liquidation_cascade.py` sections 1–3 (online clip-sizing liquidator clears every path to 300% vol; offline/bonus-0 loses; latency × lt table), section 5 (capital requirement).
**Recommendation:** Floor the bonus above zero (e.g. ≥ 0.5%); open `liquidate` to any caller (the cUSD burn at par is the only thing that must be enforced, and it is enforced by `_repay`); and consider a targetHealth closer to 1 (e.g. 1.1) so the first clip is smaller (58% of debt at 1.25 vs 100% of what is needed) — but note the `maxLiquidatable` denominator then shrinks and the `setTargetHealth` floor must move with it.
**Invariant broken:** I5 (third branch: "liquidation is profitable at the current bonus" is false at bonus 0).

---

### [LOW] The first liquidation at health = 1 clears 58% of the debt in one call (targetHealth 1.25 vs lt 0.8), wiping and permanently killing a 5% junior tranche in every scenario and touching the senior in the same call
**Location:** contracts/cap/market/BaseMarket.sol (`maxLiquidatable`, `_liquidate` junior-first loop); contracts/cap/Tranche.sol (`slash` kill latch `totalSupply > totalAssets * 100`)
**Impact:** `maxLiquidatable` at health just below 1 is `(TH − 1)/(TH − (1+b)·lt)` of debt = 0.25/0.434 = 58% at defaults (73% at TH 1.5, 84% at 2.0). On a $50M market that is a $29.4M slash. A junior tranche holding 5% of $100M ($3.1M after a 37.5% drop) is zeroed, `totalSupply > 0 = totalAssets · 100` latches `killed`, and $26M comes out of the senior. Health at 1.0001 costs underwriters $0; at 0.9999 it costs $29.4M — a cliff, not a curve — and the junior tranche is single-use by construction. Junior capital share does not help: the model shows the junior is wiped at the same shock for any junior share up to 40%.
**Likelihood:** Any price path that crosses health = 1. Design consequence, not a bug; underwriters lose more collateral than the 2% bonus suggests.
**Exploit path:** n/a. 1. Credit line fully drawn. 2. ETH −37.6%. 3. LIQUIDATOR `liquidate(…, type(uint256).max)` → $29.7M repaid, $30.3M slashed, junior at 0, `killed = true`, senior −$27M.
**Proof:** `audit/models/solvency_waterfall.py` sections 1–3 ("junior KILLED at 37.50%", n = 3–5 tranche tables), `liquidation_cascade.py` section 5.
**Recommendation:** Either lower the `setTargetHealth` floor and default (1.05–1.10) so the first clip is proportionate, or make the kill test tolerant of an *empty* tranche after a full slash (it is the survivors' share price that the latch protects, and an empty tranche has no survivors) so a wiped junior can be refilled rather than replaced.
**Invariant broken:** none; I9 (share price falls only via slash) holds by construction.

---

### [LOW] Underwriter compensation is set by the borrowing side (market owner), has floor 0, and is decoupled from every risk variable; underwriting is negative-EV below `(1+bonus)·p_default`, and 71% of tranche capital is locked exactly when the rational response is to leave
**Location:** contracts/cap/Registry.sol `_configureMarketRoles` (`setUnderwriterRate` in `ownerSelectors`); contracts/cap/InterestRateModel.sol `updateUnderwriterRate` ("There is no lower bound"); contracts/cap/market/BaseMarket.sol `_chargePremium` (no protocol fee), `lockedValue`
**Impact:** Lender yield scales with utilization (5% → 20%, ×2 with multiplier); the underwriter rate is a flat number chosen by the market owner, who is also the party paying it. Break-even rate is 2.04% at 2%/yr borrower default risk, 5.10% at 5%, 10.9% with a 15%/yr chance of a vol-triggered liquidation. At rate 0 (legal) underwriting is negative-EV at any nonzero default probability. When it turns negative the underwriter cannot leave: `lockedValue = debt/(lt − buffer)` locks 71% of tranche capital at full draw, and the queue settles only as debt is repaid. There is no protocol take anywhere in the premium path.
**Likelihood:** Structural. The owner has every incentive to set the lowest rate underwriters will tolerate, and the code lets that be 0.
**Exploit path:** n/a (incentive). 1. Owner sets `underwriterRate = 0`. 2. Underwriters queue for exit; 71% cannot settle. 3. Borrower draws the line; any default is covered by collateral that earns nothing.
**Proof:** `audit/models/rate_sweep.py` sections 2–4.
**Recommendation:** Floor the underwriter rate at a governance minimum (e.g. `>= liquidationBonus`), or let tranche depositors set a reservation rate below which `deposit` is refused; expose a `minUnderwriterRate` on the IRM alongside the existing maximum.
**Invariant broken:** none.

---

### [INFORMATIONAL] H1 confirmed as a slow clock: minted premium erodes the reserve ratio at months-to-years timescales; the sharp exposure is the fixed market's whole-term mint and utilization above ~93%
**Location:** contracts/cap/market/BaseMarket.sol `_chargePremium`; contracts/cap/Stablecoin.sol `mintCreditBacked`, `unlockedSupply`
**Impact:** At u₀ = 80% and 30% carry, reserve 20% → 15.5% after one year; it first falls under a 5%-of-supply/day instant-redemption assumption after 4.5 years (2.1 years from u₀ = 90%). Within a year only u₀ ≥ 92.9% breaches. A $10M 30-day fixed borrow mints ~$250k of premium instantly. The ratio is stable only if borrowers repay ≥ (1 − u) of accruing premium with fresh underlying (or 100% of it with existing cUSD); nothing enforces either. `DeployInfra` leaves the liquidity slopes at zero, so at deploy only the underwriter premium mints.
**Proof:** `audit/models/reserve_decay.py`.
**Recommendation:** Publish the reserve ratio and its derivative as a monitored metric; consider capping `utilizationRate()` for new borrows (a hard ceiling at, e.g., 90%) so the compounding region is never entered.

---

### [INFORMATIONAL] `burnCreditBacked` is a haircut-free exit: during a shortfall a borrower buying cUSD from a holder and repaying at face value lowers the survivors' backing ratio, and repayment funded that way never raises `unlockedSupply`
**Location:** contracts/cap/Stablecoin.sol `burnCreditBacked` (S −= a, C −= a; `badDebt` and reserve unchanged)
**Impact:** With badDebt $10M on $100M, a $10M repayment funded by cUSD bought from circulating holders moves the backing ratio 0.900 → 0.889; the selling holder left at par, the borrower discharged $1 of debt per cUSD (which trades below par during a shortfall). Separately, because `unlockedSupply = S − C − badDebt` is unchanged by such a burn, the redemption queue does not move — only repayment funded by fresh underlying (deposit-then-burn) settles it. The convex curve governs only the reserve-redemption path.
**Proof:** `audit/models/run_dynamics.py` part A (secondary-funded grid) and part B contrast.
**Recommendation:** Document that queue recovery requires new underlying; consider routing `coverBadDebt`-style retirement (burn `badDebt` alongside supply) for repayments made while `badDebt > 0`.

---

### [INFORMATIONAL] H6 refuted: the bad-debt curve is exact — 0 wei over-payment from splitting (n ≤ 1000), 0 wei round-trip gain, monotone, I1 preserved, deposit-to-improve-exit never gains, on 6/8/18-decimal underlyings across shortfall 0–99.99%
**Location:** contracts/cap/Stablecoin.sol L193-285
**Proof:** `audit/models/haircut_curve.py` — 7,020 split cases, adversarial dust splits, withdraw/redeem inverse consistency, `_onWithdraw` vs real balance. Every deviation found is in the vault's favour (max −987 wei on a 1000-way split at 99.9% shortfall, 6dp). The `_opposite` rounding claim survives.
**Recommendation:** Port T1–T6 into the invariant suite (I10/I11); the Python replica can serve as the differential oracle.

---

### [INFORMATIONAL] 13 of 18 governance parameters have a permitted range overlapping an unsafe one (table in `param_sensitivity.py` output)
**Location:** setters across `BaseMarket`, `InterestRateModel`, `FixedMarket`, `Tranche`, `Registry`
**Impact:** Beyond the four Low findings above: `termMultiplierSlope ≥ 2,516 ray` makes 1-day loans cost more than their principal (DoS of short terms); `vestingPeriod = 1 s` is legal (premium sandwich); `grace` is init-only and may be 0 (`extendAdmin` the instant a loan expires); `maximumUnderwriterRate` and the multiplier band are init-only with no setter; `maximumTermLimit` > 2.9 years makes a max-term fixed borrow's premium exceed its principal at 35% carry.
**Proof:** `audit/models/param_sensitivity.py`.
**Recommendation:** One bounded-range check per setter, with the bounds stated in the interface NatSpec.

---

## Invariants

**Broken (with the permitted parameter ranges):**
- **I5** — false for `lt > 1/(1+bonus)` (`healthiness >= 1` and `unrecoverableDebt > 0` simultaneously); false for `bonus = 0` (third branch "liquidation is profitable" never holds).

**Verified numerically (not broken):**
- **I10, I11** — hold to the wei across the full domain (`haircut_curve.py`).
- **I1** — `unlockedSupply` (18 dp) never exceeds the real balance through any redemption sequence modelled; the vault retains dust.
- **I9** — tranche share price falls only via `slash` in every walk.

**New invariants the code implies and the plan missed:**
- **I17** — `lt · (1 + liquidationBonus) <= 1e27` for every market (otherwise `healthiness` is not a leading indicator).
- **I18** — `Registry.lt/buffer/targetHealth` satisfy exactly the constraints `BaseMarket.setLt/setBuffer/setTargetHealth` enforce (`buffer < lt <= 1e27`, `targetHealth >= 1.25e27`).
- **I19** — a fixed premium is never charged at a liquidity rate below `_nextLiquidityRate(utilizationRateAfterMint(principal))` (the EMA may only raise, never lower, the fixed rate relative to spot).
- **I20** — `base + slope0 + slope1 < MAX_RATE` such that `calculateCompoundedInterest` cannot revert for any `elapsed <= 30 years`.
- **I21** — `Σ_markets unrecoverableDebt() == 0` whenever `Stablecoin.badDebt == 0` *or* the difference is bounded by a recognition SLA (this is the quantity the recognition-lag transfer is proportional to).

---

## Model outputs (verbatim)

The sections below are the exact stdout of each script, run 2026-09-09 on the `cap-network`
branch with OZ 5.7.0 pinned. Re-run with `python3 audit/models/<name>.py`.

### `reserve_decay.py`

```
reserve_decay.py  S0=$100M  demand assumption: 5% of supply/day instantly redeemable
rate curve base 5%% slope0 5%% slope1 10%% kink 80%%; underwriter rate and multiplier swept

== 1. Reserve ratio (R/S) over time, no repayments ==
u0    uw    mult | rate@u0  | day0   day30  day90  day365 | t->20%  t->10%   t->5%   t->1%   (10y horizon)
0.20  0.00  1.0  |   6.25%  | 0.800  0.799  0.798  0.790  |      -       -       -       -
0.40  0.00  1.0  |   7.50%  | 0.600  0.599  0.596  0.582  |      -       -       -       -
0.60  0.00  1.0  |   8.75%  | 0.400  0.398  0.395  0.379  |      -       -       -       -
0.70  0.00  1.0  |   9.38%  | 0.300  0.298  0.295  0.281  |   5.6y       -       -       -
0.80  0.00  1.0  |  10.00%  | 0.200  0.199  0.196  0.184  |     1d    6.5y       -       -
0.85  0.00  1.0  |  12.50%  | 0.150  0.149  0.146  0.134  |     0d    3.4y    7.9y       -
0.90  0.00  1.0  |  15.00%  | 0.100  0.099  0.097  0.087  |     0d      1d    4.6y       -
0.95  0.00  1.0  |  17.50%  | 0.050  0.049  0.048  0.042  |     0d      0d      1d    8.8y

0.20  0.00  2.0  |  12.50%  | 0.800  0.798  0.795  0.779  |      -       -       -       -
0.40  0.00  2.0  |  15.00%  | 0.600  0.597  0.591  0.563  |      -       -       -       -
0.60  0.00  2.0  |  17.50%  | 0.400  0.397  0.390  0.358  |   5.2y    8.4y       -       -
0.70  0.00  2.0  |  18.75%  | 0.300  0.297  0.290  0.262  |   2.8y    6.0y    8.3y       -
0.80  0.00  2.0  |  20.00%  | 0.200  0.197  0.192  0.168  |     1d    3.2y    5.5y    9.9y
0.85  0.00  2.0  |  25.00%  | 0.150  0.147  0.142  0.119  |     0d    1.7y    4.0y    8.4y
0.90  0.00  2.0  |  30.00%  | 0.100  0.098  0.093  0.075  |     0d      1d    2.3y    6.7y
0.95  0.00  2.0  |  35.00%  | 0.050  0.049  0.046  0.036  |     0d      0d      1d    4.4y

0.20  0.05  1.0  |  11.25%  | 0.800  0.799  0.796  0.781  |      -       -       -       -
0.40  0.05  1.0  |  12.50%  | 0.600  0.598  0.593  0.569  |      -       -       -       -
0.60  0.05  1.0  |  13.75%  | 0.400  0.397  0.392  0.367  |   6.8y       -       -       -
0.70  0.05  1.0  |  14.38%  | 0.300  0.298  0.293  0.271  |   3.7y    8.3y       -       -
0.80  0.05  1.0  |  15.00%  | 0.200  0.198  0.194  0.176  |     1d    4.6y    8.1y       -
0.85  0.05  1.0  |  17.50%  | 0.150  0.148  0.145  0.128  |     0d    2.5y    6.0y       -
0.90  0.05  1.0  |  20.00%  | 0.100  0.099  0.096  0.083  |     0d      1d    3.5y       -
0.95  0.05  1.0  |  22.50%  | 0.050  0.049  0.047  0.040  |     0d      0d      1d    7.0y

0.20  0.05  2.0  |  17.50%  | 0.800  0.798  0.793  0.770  |      -       -       -       -
0.40  0.05  2.0  |  20.00%  | 0.600  0.596  0.588  0.550  |   7.9y       -       -       -
0.60  0.05  2.0  |  22.50%  | 0.400  0.396  0.387  0.347  |   4.1y    6.8y    8.8y       -
0.70  0.05  2.0  |  23.75%  | 0.300  0.296  0.288  0.252  |   2.2y    4.9y    6.9y       -
0.80  0.05  2.0  |  25.00%  | 0.200  0.197  0.190  0.160  |     1d    2.7y    4.7y    8.6y
0.85  0.05  2.0  |  30.00%  | 0.150  0.147  0.141  0.114  |     0d    1.4y    3.4y    7.3y
0.90  0.05  2.0  |  35.00%  | 0.100  0.097  0.092  0.072  |     0d      1d    2.0y    5.9y
0.95  0.05  2.0  |  40.00%  | 0.050  0.048  0.045  0.034  |     0d      0d      1d    3.9y

0.20  0.20  1.0  |  26.25%  | 0.800  0.797  0.789  0.754  |   9.9y       -       -       -
0.40  0.20  1.0  |  27.50%  | 0.600  0.595  0.584  0.532  |   6.2y    8.7y       -       -
0.60  0.20  1.0  |  28.75%  | 0.400  0.394  0.383  0.333  |   3.3y    5.8y    7.9y       -
0.70  0.20  1.0  |  29.38%  | 0.300  0.295  0.285  0.242  |   1.8y    4.3y    6.4y       -
0.80  0.20  1.0  |  30.00%  | 0.200  0.196  0.188  0.155  |     1d    2.5y    4.5y    8.8y
0.85  0.20  1.0  |  32.50%  | 0.150  0.147  0.140  0.112  |     0d    1.4y    3.4y    7.7y
0.90  0.20  1.0  |  35.00%  | 0.100  0.097  0.092  0.072  |     0d      1d    2.1y    6.3y
0.95  0.20  1.0  |  37.50%  | 0.050  0.049  0.046  0.035  |     0d      0d      1d    4.3y

0.20  0.20  2.0  |  32.50%  | 0.800  0.796  0.787  0.742  |   7.7y    9.5y       -       -
0.40  0.20  2.0  |  35.00%  | 0.600  0.593  0.579  0.513  |   4.8y    6.6y    8.0y       -
0.60  0.20  2.0  |  37.50%  | 0.400  0.393  0.378  0.313  |   2.5y    4.3y    5.7y    8.6y
0.70  0.20  2.0  |  38.75%  | 0.300  0.293  0.280  0.225  |   1.4y    3.2y    4.6y    7.4y
0.80  0.20  2.0  |  40.00%  | 0.200  0.195  0.184  0.140  |     1d    1.8y    3.2y    6.1y
0.85  0.20  2.0  |  45.00%  | 0.150  0.145  0.136  0.099  |     0d    355d    2.4y    5.3y
0.90  0.20  2.0  |  50.00%  | 0.100  0.096  0.089  0.062  |     0d      1d    1.4y    4.3y
0.95  0.20  2.0  |  55.00%  | 0.050  0.048  0.044  0.029  |     0d      0d      1d    2.9y

== 2. Critical initial utilization: reserve ratio < 5% within horizon (no repayment) ==
uw     mult | 30d     90d     365d   (lowest grid u0 that breaches; '-' = none up to 0.95)
0.00   1.0  | 0.95     0.95     0.95 
0.00   2.0  | 0.95     0.95     0.95 
0.05   1.0  | 0.95     0.95     0.95 
0.05   2.0  | 0.95     0.95     0.95 
0.20   1.0  | 0.95     0.95     0.95 
0.20   2.0  | 0.95     0.95     0.95 

== 2b. Exact threshold search (uw 20%, mult 1x): smallest u0 breaching 5% ==
  within  30d: u0 >= 0.9486   (day-0 reserve 5.14% -> 4.99%)
  within  90d: u0 >= 0.9455   (day-0 reserve 5.45% -> 4.99%)
  within 365d: u0 >= 0.9292   (day-0 reserve 7.08% -> 5.00%)

== 3. Fixed market: whole-term premium minted at borrow (instant reserve hit) ==
  term  1d u0 0.50: $10M borrow mints $8k premium up front; reserve ratio 0.5000 -> 0.4545
  term  1d u0 0.80: $10M borrow mints $8k premium up front; reserve ratio 0.2000 -> 0.1818
  term  1d u0 0.90: $10M borrow mints $10k premium up front; reserve ratio 0.1000 -> 0.0909
  term  7d u0 0.50: $10M borrow mints $54k premium up front; reserve ratio 0.5000 -> 0.4543
  term  7d u0 0.80: $10M borrow mints $59k premium up front; reserve ratio 0.2000 -> 0.1817
  term  7d u0 0.90: $10M borrow mints $68k premium up front; reserve ratio 0.1000 -> 0.0909
  term 30d u0 0.50: $10M borrow mints $233k premium up front; reserve ratio 0.5000 -> 0.4536
  term 30d u0 0.80: $10M borrow mints $254k premium up front; reserve ratio 0.2000 -> 0.1814
  term 30d u0 0.90: $10M borrow mints $291k premium up front; reserve ratio 0.1000 -> 0.0907

== 4. Repayment: fraction f of accruing premium repaid; does the reserve ratio stabilise? ==
Analytic: (a) repaid with cUSD bought from holders (S burns, R fixed): d(R/S)/dt = -R p (1-f)/S^2 < 0 for all f < 1
          => stabilises ONLY at f = 1 (every wei of premium repaid as it accrues).
          (b) repaid with fresh underlying deposited at par (R += f p): d(R/S)/dt = p (f S - R)/S^2
          => stabilises when f >= R/S = current reserve ratio = (1 - u).
Simulation check, u0 0.80, uw 20%, mult 1x, 365 days:
  f=0.00  (a) buy-and-burn: 0.2000 -> 0.1548   (b) deposit-and-burn: 0.2000 -> 0.1548
  f=0.10  (a) buy-and-burn: 0.2000 -> 0.1590   (b) deposit-and-burn: 0.2000 -> 0.1780
  f=0.19  (a) buy-and-burn: 0.2000 -> 0.1629   (b) deposit-and-burn: 0.2000 -> 0.1979
  f=0.20  (a) buy-and-burn: 0.2000 -> 0.1633   (b) deposit-and-burn: 0.2000 -> 0.2000
  f=0.21  (a) buy-and-burn: 0.2000 -> 0.1638   (b) deposit-and-burn: 0.2000 -> 0.2021
  f=0.50  (a) buy-and-burn: 0.2000 -> 0.1766   (b) deposit-and-burn: 0.2000 -> 0.2614
  f=1.00  (a) buy-and-burn: 0.2000 -> 0.2000   (b) deposit-and-burn: 0.2000 -> 0.3527

=== HEADLINE ===
Default config (u0 80%, carry 30.0%): reserve 20% -> 15.5% after 1y with no repayment; first < 5% after 4.5y.
u0 90%: reserve 10% -> 7.2% after 1y; first < 5% after 2.1y.
The decay is SLOW (months to years) at realistic carry: H1 is a solvency clock, not a cliff. The real
exposure is the one-shot fixed-market premium and the compounding at u > 90% where carry exceeds 35%.
Reserve ratio stabilises only if borrowers repay >= (1-u) of accruing premium with FRESH deposits, or 100% of it with existing cUSD. Nothing in the protocol enforces either; the clock runs by design.
```

### `solvency_waterfall.py`

```
== 1. Shock thresholds, 2 tranches, capital split 95/5, lt 0.80 ltv 0.50 bonus 2% targetHealth 1.25 ==
credit-util | debt/K0 | health<1 at | junior wiped | senior touched | cUSD LOSS (unrec>0, jump, no liq) | unrec>0 AFTER one liquidation
     25%    |  0.125  |    84.38%   |    84.38%    |     84.38%     |             87.25%              |       87.25%      | junior KILLED at 84.38%
     50%    |  0.250  |    68.75%   |    68.75%    |     68.75%     |             74.50%              |       74.50%      | junior KILLED at 68.75%
     75%    |  0.375  |    53.13%   |    53.13%    |     53.13%     |             61.75%              |       61.75%      | junior KILLED at 53.13%
    100%    |  0.500  |    37.50%   |    37.50%    |     37.50%     |             49.00%              |       49.00%      | junior KILLED at 37.50%
    160%    |  0.800  |     0.00%   |     0.00%    |      0.00%     |             18.40%              |       18.40%      | junior KILLED at 0.00%
  analytic: health<1 at s = 1 - debt/(K0*lt); unrec>0 at s = 1 - debt*(1+bonus)/K0

== 2. Junior capital share needed so the junior absorbs a full liquidation (credit-util 100%) ==
junior share | shock at junior wiped | shock at senior touched | shock unrec>0
      5%      |        37.50%         |         37.50%          |    49.00%
     10%      |        37.50%         |         37.50%          |    49.00%
     20%      |        37.50%         |         37.50%          |    49.00%
     30%      |        37.50%         |         37.50%          |    49.00%
     40%      |        37.50%         |         37.50%          |    49.00%
     50%      |        38.29%         |         38.29%          |    49.00%
  at shock 37.51% (health just < 1): maxLiquidatable = $28.8M of $50M debt, slash = $29.4M; junior 5% holds $3.1M

== 3. 3-5 tranches (capital by weight), credit-util 100%: which tranches a single liquidation reaches ==
  n=3 shock 40%: liq $33.4M slashed(senior..junior)=['$22.1M', '$9.0M', '$3.0M'] killed=[1, 2] h_post=1.250 unrec_post=$0.00M
  n=3 shock 45%: liq $42.6M slashed(senior..junior)=['$32.5M', '$8.2M', '$2.8M'] killed=[1, 2] h_post=1.250 unrec_post=$0.00M
  n=3 shock 48%: liq $48.2M slashed(senior..junior)=['$38.7M', '$7.8M', '$2.6M'] killed=[1, 2] h_post=1.250 unrec_post=$0.00M
  n=3 shock 49%: liq $50.0M slashed(senior..junior)=['$40.8M', '$7.7M', '$2.6M'] killed=[0, 1, 2] h_post=1.250 unrec_post=$0.00M
  n=3 shock 50%: liq $49.0M slashed(senior..junior)=['$40.0M', '$7.5M', '$2.5M'] killed=[0, 1, 2] h_post=0.000 unrec_post=$0.98M
  n=4 shock 40%: liq $33.4M slashed(senior..junior)=['$16.1M', '$9.0M', '$6.0M', '$3.0M'] killed=[1, 2, 3] h_post=1.250 unrec_post=$0.00M
  n=4 shock 45%: liq $42.6M slashed(senior..junior)=['$27.0M', '$8.2M', '$5.5M', '$2.8M'] killed=[1, 2, 3] h_post=1.250 unrec_post=$0.00M
  n=4 shock 48%: liq $48.2M slashed(senior..junior)=['$33.5M', '$7.8M', '$5.2M', '$2.6M'] killed=[1, 2, 3] h_post=1.250 unrec_post=$0.00M
  n=4 shock 49%: liq $50.0M slashed(senior..junior)=['$35.7M', '$7.7M', '$5.1M', '$2.6M'] killed=[0, 1, 2, 3] h_post=1.250 unrec_post=$0.00M
  n=4 shock 50%: liq $49.0M slashed(senior..junior)=['$35.0M', '$7.5M', '$5.0M', '$2.5M'] killed=[0, 1, 2, 3] h_post=0.000 unrec_post=$0.98M
  n=5 shock 40%: liq $33.4M slashed(senior..junior)=['$10.1M', '$9.0M', '$6.0M', '$6.0M', '$3.0M'] killed=[1, 2, 3, 4] h_post=1.250 unrec_post=$0.00M
  n=5 shock 45%: liq $42.6M slashed(senior..junior)=['$21.5M', '$8.2M', '$5.5M', '$5.5M', '$2.8M'] killed=[1, 2, 3, 4] h_post=1.250 unrec_post=$0.00M
  n=5 shock 48%: liq $48.2M slashed(senior..junior)=['$28.3M', '$7.8M', '$5.2M', '$5.2M', '$2.6M'] killed=[1, 2, 3, 4] h_post=1.250 unrec_post=$0.00M
  n=5 shock 49%: liq $50.0M slashed(senior..junior)=['$30.6M', '$7.7M', '$5.1M', '$5.1M', '$2.6M'] killed=[0, 1, 2, 3, 4] h_post=1.250 unrec_post=$0.00M
  n=5 shock 50%: liq $49.0M slashed(senior..junior)=['$30.0M', '$7.5M', '$5.0M', '$5.0M', '$2.5M'] killed=[0, 1, 2, 3, 4] h_post=0.000 unrec_post=$0.98M

== 4. Is healthiness() leading or lagging real protection? ==
real protection = recoverableDebt / totalDebt = K / ((1+bonus) * debt); healthiness = K*lt/debt
healthiness == 1  <=>  K = debt/lt ;  protection == 1  <=>  K = debt*(1+bonus)
  lt 0.7000 bonus 2%: protection at health=1 is 1.4006; LEADS by 28.60% of price
  lt 0.8000 bonus 2%: protection at health=1 is 1.2255; LEADS by 18.40% of price
  lt 0.9000 bonus 2%: protection at health=1 is 1.0893; LEADS by 8.20% of price
  lt 0.9500 bonus 2%: protection at health=1 is 1.0320; LEADS by 3.10% of price
  lt 0.9800 bonus 2%: protection at health=1 is 1.0004; LEADS by 0.04% of price
  lt 0.9804 bonus 2%: protection at health=1 is 1.0000; LAGS: unrec>0 while healthiness>=1
  lt 0.9900 bonus 2%: protection at health=1 is 0.9903; LAGS: unrec>0 while healthiness>=1
  lt 1.0000 bonus 2%: protection at health=1 is 0.9804; LAGS: unrec>0 while healthiness>=1
  threshold: healthiness lags real protection when lt > 1/(1+bonus) = 0.9804 (setLt permits up to 1.0)
  In the TIME dimension healthiness lags: premium accrues into debt every block with no price move,
  and a fixed borrow adds its whole-term premium instantly, so health moves before price does.

  Shock path (2 tranches 95/5, credit-util 100%), liquidator acts each step:
  step shock | health | protection | unrec | liq this step | cumulative slash | junior | senior
   10.0%     | 1.440  |   1.000    | $0.0M | $0.0M | $0.0M | $4.5M | $85.5M
   20.0%     | 1.280  |   1.000    | $0.0M | $0.0M | $0.0M | $4.0M | $76.0M
   30.0%     | 1.120  |   1.000    | $0.0M | $0.0M | $0.0M | $3.5M | $66.5M
   35.0%     | 1.040  |   1.000    | $0.0M | $0.0M | $0.0M | $3.2M | $61.8M
   37.5%     | 1.000  |   1.000    | $0.0M | $28.8M | $29.4M | $0.0M | $33.1M
   40.0%     | 1.200  |   1.000    | $0.0M | $0.0M | $29.4M | $0.0M | $31.8M
   45.0%     | 1.100  |   1.000    | $0.0M | $0.0M | $29.4M | $0.0M | $29.1M
   50.0%     | 1.000  |   1.000    | $0.0M | $0.0M | $29.4M | $0.0M | $26.5M
   55.0%     | 0.900  |   1.000    | $0.0M | $17.1M | $46.8M | $0.0M | $6.4M
  With prompt liquidation at every step the path never reaches unrec>0: each liquidation resets health to
  targetHealth. The loss to cUSD holders needs a single JUMP (or liquidator absence) of size >= the cushion.

=== HEADLINE ===
Defaults (lt 0.8, ltv 0.5, bonus 2%, 95/5): at full credit-line draw, health<1 at a 37.5% correlated price drop; cUSD holders take a loss (unrecoverableDebt>0) at 49.0% if no liquidation lands in between.
The 5% junior is wiped (and permanently KILLED) by the FIRST liquidation at any credit-util; the senior is touched in the same call:
restoring health from 1.0 to targetHealth 1.25 liquidates 58% of the debt in one call (perCleared = 1.25 - 1.02*0.8 = 0.434).
healthiness() LEADS unrecoverable debt by (1 - (1+bonus)*lt) = 18.4% of price at defaults, but LAGS whenever lt > 0.9804, which setLt permits (up to 1.0).
```

### `haircut_curve.py`

```
== Curve shape (supply $50M, 18dp): payout per share for redeeming fraction f of supply ==
  shortfall | f=0.1%% | f=10%% | f=50%% | f=100%% | backing ratio | ratio^2 
    1.00%  | 0.980110 | 0.981081 | 0.985025 | 0.990000 | 0.990000 | 0.980100
   10.00%  | 0.810081 | 0.818182 | 0.852632 | 0.900000 | 0.900000 | 0.810000
   50.00%  | 0.250125 | 0.263158 | 0.333333 | 0.500000 | 0.500000 | 0.250000
   90.00%  | 0.010009 | 0.010989 | 0.018182 | 0.100000 | 0.100000 | 0.010000
   99.99%  | 0.000000 | 0.000000 | 0.000000 | 0.000100 | 0.000100 | 0.000000
== Sequential redeemers (10 x 5% of supply, shortfall 20%, no credit): per-share payout ==
  0.64646 0.65966 0.67326 0.68729 0.70175 0.71669 0.73210 0.74801 0.76445 0.78144
  monotone increasing: True  (design intent: later redeemer gets MORE per share)
== T1 split-equivalence: n calls vs 1 call (positive deviation = split pays MORE) ==
  cases: 7020
  max POSITIVE deviation (split pays more): 0 wei  inputs=None
  max NEGATIVE deviation (split pays less): -987 wei  inputs=(50000000000000000000000000, 9990, 6, 24975000000000000000000, 1000, False)
== T1b adversarial: 1000 redemptions of tiny size, decimals 6, deep shortfall ==
  max positive deviation: 0 wei  inputs=None
== T2 round-trip deposit -> redeem (I11): payout - deposit, positive = vault loses ==
  max (payout - deposit): 0 wei  inputs=None
== T3 previewRedeem monotonic in shares ==
  violation: None
== T4 _onWithdraw keeps unlockedSupply <= real balance (I1) and badDebt consistent ==
  max (unlockedSupply - balance) in 18dp wei: 0  inputs=(1000000000000000000000000, 0, 6, 500000000000000000000000)  (>0 would break I1)
  max dust retained by vault (balance - unlocked): 3000000000000 wei-18dp
  badDebt clamp (reduced > badDebt) hit: 0 times
== T5 withdraw/redeem inverse consistency ==
  max a - previewRedeem(previewWithdraw(a)) [assets wei]: 0  inputs=None
     (withdraw pays `a` for previewWithdraw(a) shares; a value > 1 asset-wei means the withdrawer
      is paid more than those shares are worth under redeem -> compare to 1 unit of underlying)
  max previewWithdraw(previewRedeem(s)) - s [shares]: 0  inputs=None
== T6 deposit-at-par-then-redeem vs plain redeem (positive = attacker gains) ==
  max attacker gain: -18736455 asset-wei  inputs=(1000000000000000000000000, 100, 6, 693000000000000000000000, 10000000000)

=== HEADLINE ===
split-equivalence max over-payment: 0 wei (I10 HOLDS)
dust split max over-payment:        0 wei
round-trip max over-payment:        0 wei (I11 HOLDS)
monotonicity violation:             False
I1 (unlocked <= balance) max gap:   0 wei (HOLDS)
withdraw-vs-redeem slack (assets):  0 wei
deposit-to-improve-exit max gain:   -18736455 asset-wei (claim HOLDS)
```

### `liquidation_cascade.py`

```
liquidation_cascade.py  K0=$100M ETH-like, debt = ltv*K0 = $50M, carry 30%, 30d hourly GBM, 80 paths/cell
impact: LAMBDA 1.0, depth 5000 units per 1%, PERM 0.5

== 1. Defaults (lt 0.8, targetHealth 1.25, bonus 2%): P(cUSD loss within 30d) by vol ==
vol   | P(loss) | avg unrec when loss | clips/path | max cUSD burned in one hour (liquidator capital) | stalled steps/path
  40% |  0.00   |    $    0.00M      |       0.00        |            $   0.0M                    |   0.0
  60% |  0.00   |    $    0.00M      |       0.00        |            $   0.0M                    |   0.0
  80% |  0.00   |    $    0.00M      |       0.03        |            $  11.1M                    |   0.0
 100% |  0.00   |    $    0.00M      |       0.39        |            $  11.3M                    |   0.0
 125% |  0.00   |    $    0.00M      |       0.72        |            $  11.3M                    |   0.0
 150% |  0.00   |    $    0.00M      |       1.00        |            $  21.4M                    |   0.0
 200% |  0.00   |    $    0.00M      |       2.12        |            $  21.4M                    |   0.0
 300% |  0.00   |    $    0.00M      |       3.71        |            $  31.0M                    |   0.0

== 2. Liquidator OFFLINE (H11: single privileged actor): P(loss) by vol ==
 vol  60%: P(loss) 0.00  avg unrec $0.00M
 vol  80%: P(loss) 0.00  avg unrec $0.00M
 vol 100%: P(loss) 0.04  avg unrec $7.44M
 vol 150%: P(loss) 0.12  avg unrec $9.40M

== 3a. Liquidator LATENCY x lt at 100% vol, bonus 2%, TH 1.25: P(cUSD loss in 30d) ==
  (the liquidator checks the market every N hours; 'never' = offline). cushion = 1-(1+b)*lt = price drop from h=1 to unrec>0
  lt   | cushion |  1h   |  6h   |  24h  |  72h  | never
  0.70 |  28.6%  |  0.00 |  0.00 |  0.00 |  0.00 |  0.00
  0.80 |  18.4%  |  0.00 |  0.00 |  0.00 |  0.00 |  0.02
  0.90 |   8.2%  |  0.00 |  0.02 |  0.00 |  0.05 |  0.05
  0.95 |   3.1%  |  0.00 |  0.02 |  0.05 |  0.05 |  0.08

== 3b. Same at 150% vol ==
  lt   | cushion |  1h   |  6h   |  24h  |  72h  | never
  0.70 |  28.6%  |  0.00 |  0.00 |  0.00 |  0.00 |  0.13
  0.80 |  18.4%  |  0.00 |  0.00 |  0.00 |  0.02 |  0.12
  0.90 |   8.2%  |  0.00 |  0.03 |  0.12 |  0.15 |  0.15
  0.95 |   3.1%  |  0.12 |  0.08 |  0.15 |  0.15 |  0.15

== 3c. bonus x lt x targetHealth: first-liquidation size at h=1 and vol at which an ONLINE liquidator still loses ==
bonus | lt   | targetHealth | perCleared = TH-(1+b)*lt | first-liq size at h=1 (% of debt) | vol threshold P(loss)>=50%
   0%  | 0.70 |     1.25     |        0.550             |    45%                          |    300%
   0%  | 0.70 |     1.50     |        0.800             |    62%                          |    >300%
   0%  | 0.70 |     2.00     |        1.300             |    77%                          |    300%
   0%  | 0.80 |     1.25     |        0.450             |    56%                          |    300%
   0%  | 0.80 |     1.50     |        0.700             |    71%                          |    >300%
   0%  | 0.80 |     2.00     |        1.200             |    83%                          |    >300%
   0%  | 0.90 |     1.25     |        0.350             |    71%                          |    300%
   0%  | 0.90 |     1.50     |        0.600             |    83%                          |    300%
   0%  | 0.90 |     2.00     |        1.100             |    91%                          |    300%
   2%  | 0.70 |     1.25     |        0.536             |    47%                          |    >300%
   2%  | 0.70 |     1.50     |        0.786             |    64%                          |    >300%
   2%  | 0.70 |     2.00     |        1.286             |    78%                          |    >300%
   2%  | 0.80 |     1.25     |        0.434             |    58%                          |    >300%
   2%  | 0.80 |     1.50     |        0.684             |    73%                          |    >300%
   2%  | 0.80 |     2.00     |        1.184             |    84%                          |    >300%
   2%  | 0.90 |     1.25     |        0.332             |    75%                          |    >300%
   2%  | 0.90 |     1.50     |        0.582             |    86%                          |    >300%
   2%  | 0.90 |     2.00     |        1.082             |    92%                          |    >300%
  10%  | 0.70 |     1.25     |        0.480             |    52%                          |    >300%
  10%  | 0.70 |     1.50     |        0.730             |    68%                          |    >300%
  10%  | 0.70 |     2.00     |        1.230             |    81%                          |    >300%
  10%  | 0.80 |     1.25     |        0.370             |    68%                          |    >300%
  10%  | 0.80 |     1.50     |        0.620             |    81%                          |    >300%
  10%  | 0.80 |     2.00     |        1.120             |    89%                          |    >300%
  10%  | 0.90 |     1.25     |        0.260             |    96%                          |    300%
  10%  | 0.90 |     1.50     |        0.510             |    98%                          |    300%
  10%  | 0.90 |     2.00     |        1.010             |    99%                          |    300%
  bonus 0% rows equal the OFFLINE case: no clip is ever profitable, so the liquidator never acts.

== 4. Liquidator economics per unit of debt cleared (no path; static) ==
collateral/debt | recoverable share | bonus 0% | bonus 2% | bonus 5% | bonus 10%   (profit per $1 cUSD burned, before impact)
     1.50       |   1.00/1.00/1.00/1.00   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     1.25       |   1.00/1.00/1.00/1.00   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     1.10       |   1.00/1.00/1.00/1.00   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     1.05       |   1.00/1.00/1.00/0.95   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     1.02       |   1.00/1.00/0.97/0.93   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     1.00       |   1.00/0.98/0.95/0.91   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     0.90       |   0.90/0.88/0.86/0.82   |  +0.0% |  +2.0% |  +5.0% | +10.0%
     0.50       |   0.50/0.49/0.48/0.45   |  +0.0% |  +2.0% |  +5.0% | +10.0%
  The liquidator ALWAYS earns exactly the bonus per unit cleared (maxLiquidatable is capped at
  recoverableDebt, so the tranche is never asked for more than it holds). Below 100% collateral the
  liquidator still profits on the recoverable slice; the UNRECOVERABLE slice is simply not liquidatable
  and lands on cUSD holders via writeOff. Net of impact the trade is profitable iff bonus > impact:
   bonus   0%: liquidation is NEVER profitable (proceeds <= cUSD burned); permitted by setLiquidationBonus(0)
   bonus   2%: largest single clip that still clears =  10000 units (~$20.0M at $2000, depth 5000/1%)
   bonus   5%: largest single clip that still clears =  25000 units (~$50.0M at $2000, depth 5000/1%)
   bonus  10%: largest single clip that still clears =  50000 units (~$100.0M at $2000, depth 5000/1%)

== 4b. Depth sensitivity at 100% vol, defaults: P(loss) and clips by book depth ==
  depth  1000 units/1% (~$  2M): P(loss) 0.00  clips/path   2.3  max cUSD/hour $27.3M  stalled 0.0
  depth  2000 units/1% (~$  4M): P(loss) 0.00  clips/path   0.8  max cUSD/hour $8.8M  stalled 0.0
  depth  5000 units/1% (~$ 10M): P(loss) 0.00  clips/path   0.3  max cUSD/hour $11.3M  stalled 0.0
  depth 20000 units/1% (~$ 40M): P(loss) 0.00  clips/path   0.2  max cUSD/hour $31.3M  stalled 0.0

== 5. Capital requirement: cUSD the liquidator must hold at the first liquidation ==
  credit-util  50% shock 69.0%: debt $25M, maxLiquidatable $14.9M (59% of debt) -> liquidator needs $14.9M cUSD at par
  credit-util  50% shock 72.0%: debt $25M, maxLiquidatable $20.4M (82% of debt) -> liquidator needs $20.4M cUSD at par
  credit-util  50% shock 74.5%: debt $25M, maxLiquidatable $25.0M (100% of debt) -> liquidator needs $25.0M cUSD at par
  credit-util 100% shock 38.0%: debt $50M, maxLiquidatable $29.7M (59% of debt) -> liquidator needs $29.7M cUSD at par
  credit-util 100% shock 45.0%: debt $50M, maxLiquidatable $42.6M (85% of debt) -> liquidator needs $42.6M cUSD at par
  credit-util 100% shock 49.0%: debt $50M, maxLiquidatable $50.0M (100% of debt) -> liquidator needs $50.0M cUSD at par

=== HEADLINE ===
Defaults, ETH at 80% vol, 30d: P(cUSD loss) = 0.00 with a clip-sizing liquidator online vs 0.00 offline; P(loss) >= 50% only above ~300% annualised vol.
The first liquidation at health=1 wants 58% of debt at TH 1.25 (73% at TH 1.5, 84% at TH 2.0); at 2% bonus the
largest clip with positive edge is ~$20M at the stated depth, so restoring health takes several clips whose
permanent impact lowers the oracle price for the next. Bonus 0% (permitted) makes every liquidation unprofitable.
```

### `rate_sweep.py`

```
rate_sweep.py  curve base 5%/slope0 5%/slope1 10%/kink 80%; bonus 2%; ltv 0.5; protocol take = 0 (none exists)

== 1. Rates across stablecoin utilization u ==
  u    | liqRate(u) | lender yield/cUSD (x1) | (x2 mult) | underwriter rate (flat, owner-set, floor 0) | protocol
 0.00  |    5.00%   |         0.00%          |   0.00%   |         0% .. 100%, NOT a function of u          |   0%
 0.20  |    6.25%   |         1.25%          |   2.50%   |         0% .. 100%, NOT a function of u          |   0%
 0.40  |    7.50%   |         3.00%          |   6.00%   |         0% .. 100%, NOT a function of u          |   0%
 0.60  |    8.75%   |         5.25%          |  10.50%   |         0% .. 100%, NOT a function of u          |   0%
 0.80  |   10.00%   |         8.00%          |  16.00%   |         0% .. 100%, NOT a function of u          |   0%
 0.85  |   12.50%   |        10.62%          |  21.25%   |         0% .. 100%, NOT a function of u          |   0%
 0.90  |   15.00%   |        13.50%          |  27.00%   |         0% .. 100%, NOT a function of u          |   0%
 0.95  |   17.50%   |        16.62%          |  33.25%   |         0% .. 100%, NOT a function of u          |   0%
 1.00  |   20.00%   |        20.00%          |  40.00%   |         0% .. 100%, NOT a function of u          |   0%
  The liquidity rate rises with u (lenders are paid for scarcity); the underwriter rate does NOT move with
  anything - not utilization, not collateral vol, not health. Underwriter compensation is decoupled from risk.

== 2. Underwriter expected return per $1 of tranche capital, leverage L = debt/K = ltv = 0.50 ==
  gross = uwRate*L ; loss = p_def*L*(1+b) + p_vol*0.58*(1+b)*L
  uwRate | pDef  1% pVol  0% | pDef  1% pVol  5% | pDef  1% pVol 15% | pDef  2% pVol  0% | pDef  2% pVol  5% | pDef  2% pVol 15% | pDef  5% pVol  0% | pDef  5% pVol  5% | pDef  5% pVol 15% | pDef 10% pVol  0% | pDef 10% pVol  5% | pDef 10% pVol 15%
    0.0% |           -0.51% |           -1.99% |           -4.95% |           -1.02% |           -2.50% |           -5.46% |           -2.55% |           -4.03% |           -6.99% |           -5.10% |           -6.58% |           -9.54%
    1.0% |           -0.01% |           -1.49% |           -4.45% |           -0.52% |           -2.00% |           -4.96% |           -2.05% |           -3.53% |           -6.49% |           -4.60% |           -6.08% |           -9.04%
    2.0% |           +0.49% |           -0.99% |           -3.95% |           -0.02% |           -1.50% |           -4.46% |           -1.55% |           -3.03% |           -5.99% |           -4.10% |           -5.58% |           -8.54%
    3.0% |           +0.99% |           -0.49% |           -3.45% |           +0.48% |           -1.00% |           -3.96% |           -1.05% |           -2.53% |           -5.49% |           -3.60% |           -5.08% |           -8.04%
    5.0% |           +1.99% |           +0.51% |           -2.45% |           +1.48% |           +0.00% |           -2.96% |           -0.05% |           -1.53% |           -4.49% |           -2.60% |           -4.08% |           -7.04%
    8.0% |           +3.49% |           +2.01% |           -0.95% |           +2.98% |           +1.50% |           -1.46% |           +1.45% |           -0.03% |           -2.99% |           -1.10% |           -2.58% |           -5.54%
   10.0% |           +4.49% |           +3.01% |           +0.05% |           +3.98% |           +2.50% |           -0.46% |           +2.45% |           +0.97% |           -1.99% |           -0.10% |           -1.58% |           -4.54%
   20.0% |           +9.49% |           +8.01% |           +5.05% |           +8.98% |           +7.50% |           +4.54% |           +7.45% |           +5.97% |           +3.01% |           +4.90% |           +3.42% |           +0.46%
   50.0% |          +24.49% |          +23.01% |          +20.05% |          +23.98% |          +22.50% |          +19.54% |          +22.45% |          +20.97% |          +18.01% |          +19.90% |          +18.42% |          +15.46%

== 3. Break-even underwriter rate (below which underwriting is negative EV), by p_def x p_vol ==
  Independent of L (both sides scale with leverage) => the threshold is a pure rate:
   p_def   1%: pVol  0% -> uwRate* >=  1.02%  pVol  5% -> uwRate* >=  3.98%  pVol 15% -> uwRate* >=  9.89%
   p_def   2%: pVol  0% -> uwRate* >=  2.04%  pVol  5% -> uwRate* >=  5.00%  pVol 15% -> uwRate* >= 10.91%
   p_def   5%: pVol  0% -> uwRate* >=  5.10%  pVol  5% -> uwRate* >=  8.06%  pVol 15% -> uwRate* >= 13.97%
   p_def  10%: pVol  0% -> uwRate* >= 10.20%  pVol  5% -> uwRate* >= 13.16%  pVol 15% -> uwRate* >= 19.07%
  CapDeployer default 20% clears every cell; production default is whatever the market owner sets,
  and the code permits 0%, at which underwriting is negative EV at ANY nonzero default probability.

== 4. When the system needs underwriters most: utilization high, collateral falling ==
  At u -> 1 the lender rate doubles (10% -> 20%, or 40% at x2) while the underwriter rate stays flat.
  Underwriter net EV is invariant to u, but the tranche's REDEEMABILITY is not: lockedValue = debt/(lt-buffer)
  = debt/0.7 = 1.43x debt is locked in the tranches, so at credit-util 100% (debt = 0.5 K) 71% of K cannot
  leave. The rational underwriter therefore queues to exit whenever expected return turns negative, and
  the queue only settles as debt is repaid - i.e. exactly when repayment is least likely.
   credit-util  25%: locked share of tranche capital = 18%, free to exit = 82%
   credit-util  50%: locked share of tranche capital = 36%, free to exit = 64%
   credit-util  75%: locked share of tranche capital = 54%, free to exit = 46%
   credit-util 100%: locked share of tranche capital = 71%, free to exit = 29%

== 5. Fee-to-risk mismatch summary ==
  uwRate  0.0%: tolerates borrower default probability up to  0.00%/yr (p_vol=0) before EV < 0
  uwRate  2.0%: tolerates borrower default probability up to  1.96%/yr (p_vol=0) before EV < 0
  uwRate  5.0%: tolerates borrower default probability up to  4.90%/yr (p_vol=0) before EV < 0
  uwRate 20.0%: tolerates borrower default probability up to 19.61%/yr (p_vol=0) before EV < 0

=== HEADLINE ===
Underwriting is negative-EV whenever underwriterRate < (1+bonus)*(p_default + 0.58*p_volLiq): at 2%/yr
default risk that is 2.04%; at 5% it is 5.10%. The rate is set by the MARKET OWNER (the borrowing side),
has floor 0, and does not respond to utilization, health, or vol. Protocol take: none.
```

### `run_dynamics.py`

```
run_dynamics.py  S0=$100M, u0 80%, reserve $20M, underlying 6dp

== A. Queue wait vs daily withdrawal fraction w and FRESH-funded repayment rate r (badDebt 0, 120 days) ==
  Reserve 20% serves instantly; beyond it the queue settles only as fresh underlying enters via repayment.
  w/day | r=0.0%/d | r=0.5%/d | r=1%/d | r=2%/d | r=5%/d      (max wait in days; 'stuck' = never claimable in 120d)
   0.5% |   0d +77 stuck |   0d         |   0d         |   0d         |   0d        
   1.0% |   0d +99 stuck |  38d +39 stuck |   0d         |   0d         |   0d        
   2.0% |   0d +110 stuck |  80d +80 stuck |  50d +50 stuck |   0d         |   0d        
   5.0% |   0d +117 stuck | 104d +105 stuck |  93d +93 stuck |  69d +69 stuck |   0d        
  10.0% |   0d +119 stuck |  96d +114 stuck | 102d +108 stuck |  95d +96 stuck |  60d +60 stuck
  20.0% |   0d +121 stuck |  87d +118 stuck | 106d +115 stuck | 100d +110 stuck |  90d +93 stuck

  Same grid, SECONDARY-funded repayment (borrower buys cUSD from holders): unlockedSupply never moves
   0.5% | r=0:   0d +77 stuck | r=1%:   0d +64 stuck | r=5%:   0d        
   2.0% | r=0:   0d +110 stuck | r=1%:   0d +69 stuck | r=5%:   0d +30 stuck
  10.0% | r=0:   0d +119 stuck | r=1%:   0d +25 stuck | r=5%:   0d +14 stuck

  Threshold (fresh-funded): smallest w such that max wait > T
   T= 7d repay 0.5%/d: orderly redemption breaks at w >= 0.62%/day (cumulative 4% of supply in 7 days)
   T= 7d repay 1.0%/d: orderly redemption breaks at w >= 1.12%/day (cumulative 8% of supply in 7 days)
   T= 7d repay 2.0%/d: orderly redemption breaks at w >= 2.12%/day (cumulative 14% of supply in 7 days)
   T= 7d repay 5.0%/d: orderly redemption breaks at w >= 5.12%/day (cumulative 31% of supply in 7 days)
   T=30d repay 0.5%/d: orderly redemption breaks at w >= 0.62%/day (cumulative 17% of supply in 30 days)
   T=30d repay 1.0%/d: orderly redemption breaks at w >= 1.12%/day (cumulative 29% of supply in 30 days)
   T=30d repay 2.0%/d: orderly redemption breaks at w >= 2.12%/day (cumulative 47% of supply in 30 days)
   T=30d repay 5.0%/d: orderly redemption breaks at w >= 5.12%/day (cumulative 79% of supply in 30 days)

== B. Early vs late redeemer under the exact curve (badDebt 10% recognised day 0, w rises with badDebt) ==
  claim day | requested day | payout per share (underlying)
       0    |       0       |   0.815710
       1    |       1       |   0.826634
       2    |       2       |   0.836547
       5    |       5       |   0.858271
      32    |      10       |   0.890982
  payout per share non-decreasing along the queue: True   badDebt end: $1.67M (from $10M)  claims settled: 72
  => under RECOGNISED bad debt the curve does what it claims: the early redeemer gets LESS per share.

  Contrast - the par channel the curve does not cover: borrower repays $10M with cUSD bought from holders
  backing ratio 0.9000 -> 0.8889; whole-supply exit per share 0.9000 -> 0.8889. The seller left at par, the
  borrower discharged $1 of debt per cUSD, and the survivors' backing fell: burnCreditBacked is a
  haircut-free exit for whoever sells cUSD to a repaying borrower.

== C. Recognition lag: unrecoverable debt exists at day 0 but writeOff lands at day t_w ==
  Before t_w the reserve pays par; after t_w the survivors carry the whole shortfall.
  t_w | exits before t_w (share of supply) | paid at par | loss borne by survivors | survivors' payout/share after t_w
    0 |   0.0%                              | $ 0.00M    | $0.00M transferred       | 0.9000
    3 |   5.9%                              | $ 5.88M    | $0.59M transferred       | 0.8938
    7 |  13.2%                              | $13.19M    | $1.32M transferred       | 0.8848
   14 |  20.0%                              | $20.00M    | $2.00M transferred       | 0.8750
   30 |  20.0%                              | $20.00M    | $2.00M transferred       | 0.8750
  With a 10% shortfall, every $1 that exits before writeOff moves $0.10 of loss onto those who stay.
  writeOff is a discretionary GUARDIAN action bounded only by unrecoverableDebt (H3), so the lag is unbounded.

=== HEADLINE ===
Orderly redemption (wait <= 7d) breaks once daily requests exceed ~1% of supply at 1%/day repayment
(the 20% reserve absorbs ~10 days of it); with no repayment anything past the reserve is stuck indefinitely.
The convex haircut DOES remove the first-mover advantage for RECOGNISED bad debt (payout/share is monotone
increasing along the queue). It does NOT touch unrecognised bad debt: exits before writeOff are paid par,
and each $1 out before recognition shifts (shortfall/supply) of loss onto the survivors.
```

### `ema_manipulation.py`

```
ema_manipulation.py  S=$100M, r_alt 5%, term = max = 30d, gas $20

== live utilization 80% (rate 10.00%) ==
  loan $1M: honest 30d premium $8301 (rate at u_after_mint 10.10%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $2460     | $2553     |  31.89% | $1790
      15m  | $0.1M                  | $153M       | $2314     | $2553     |  31.89% | $1718
       1h  | $0.1M                  | $153M       | $1660     | $2553     |  31.89% | $1390
       4h  | $0.1M                  | $35M        | $312      | $1138     |  59.43% | $261
      12h  | $0.1M                  | $0M         | $44       | $82       |  79.99% | $14
      24h  | $0.1M                  | $0M         | $26       | $82       |  79.99% | $5
  loan $10M: honest 30d premium $89664 (rate at u_after_mint 10.91%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $30896    | $30989    |  34.22% | $23722
      15m  | $0.1M                  | $153M       | $30751    | $30989    |  34.22% | $23649
       1h  | $0.1M                  | $153M       | $30096    | $30989    |  34.22% | $23322
       4h  | $0.1M                  | $153M       | $27476    | $30989    |  34.22% | $22012
      12h  | $0.1M                  | $153M       | $20489    | $30989    |  34.22% | $18519
      24h  | $0.1M                  | $73M        | $13284    | $23372    |  49.05% | $12009
  loan $50M: honest 30d premium $547945 (rate at u_after_mint 13.33%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $232176   | $232268   |  42.90% | $194992
      15m  | $0.1M                  | $153M       | $232030   | $232268   |  42.90% | $194919
       1h  | $0.1M                  | $153M       | $231375   | $232268   |  42.90% | $194592
       4h  | $0.1M                  | $153M       | $228755   | $232268   |  42.90% | $193282
      12h  | $0.1M                  | $153M       | $221769   | $232268   |  42.90% | $189789
      24h  | $0.1M                  | $153M       | $211289   | $232268   |  42.90% | $184549

== live utilization 90% (rate 15.00%) ==
  loan $1M: honest 30d premium $12369 (rate at u_after_mint 15.05%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $6327     | $6419     |  35.83% | $5570
      15m  | $0.1M                  | $153M       | $6181     | $6419     |  35.83% | $5497
       1h  | $0.1M                  | $153M       | $5526     | $6419     |  35.83% | $5170
       4h  | $0.1M                  | $40M        | $4011     | $4942     |  64.59% | $3919
      12h  | $0.1M                  | $13M        | $3240     | $4169     |  79.63% | $1809
      24h  | $0.1M                  | $13M        | $2330     | $4169     |  79.63% | $1354
  loan $10M: honest 30d premium $127024 (rate at u_after_mint 15.45%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $66303    | $66396    |  38.02% | $58328
      15m  | $0.1M                  | $153M       | $66158    | $66396    |  38.02% | $58255
       1h  | $0.1M                  | $153M       | $65503    | $66396    |  38.02% | $57927
       4h  | $0.1M                  | $153M       | $62883    | $66396    |  38.02% | $56617
      12h  | $0.1M                  | $153M       | $55896    | $66396    |  38.02% | $53124
      24h  | $0.1M                  | $83M        | $47921    | $59317    |  51.80% | $46317
  loan $50M: honest 30d premium $684932 (rate at u_after_mint 16.67%)
  period   | t=period: break-even D | best D      | profit    | saved     | u_manip | t=period/2 profit@bestD
       5m  | $0.1M                  | $153M       | $360685   | $360778   |  46.20% | $320639
      15m  | $0.1M                  | $153M       | $360540   | $360778   |  46.20% | $320566
       1h  | $0.1M                  | $153M       | $359885   | $360778   |  46.20% | $320238
       4h  | $0.1M                  | $153M       | $357265   | $360778   |  46.20% | $318928
      12h  | $0.1M                  | $153M       | $350278   | $360778   |  46.20% | $315435
      24h  | $0.1M                  | $153M       | $339798   | $360778   |  46.20% | $310195

== termMultiplier: shorter terms pay MORE (slope 0.5e27), so the max term is both the cheapest and the
   one that locks the manipulated rate longest; the multiplier does not touch the attack at max term ==
  term  1d slope 0.0: multiplier 1.000 honest $4234    manipulated(D=1x S, t=1d) $2185    saved $2049
  term  1d slope 0.5: multiplier 1.483 honest $6281    manipulated(D=1x S, t=1d) $3241    saved $3039
  term  7d slope 0.0: multiplier 1.000 honest $29639   manipulated(D=1x S, t=1d) $15297   saved $14342
  term  7d slope 0.5: multiplier 1.383 honest $41000   manipulated(D=1x S, t=1d) $21161   saved $19840
  term 15d slope 0.0: multiplier 1.000 honest $63512   manipulated(D=1x S, t=1d) $32779   saved $30733
  term 15d slope 0.5: multiplier 1.250 honest $79390   manipulated(D=1x S, t=1d) $40974   saved $38416
  term 30d slope 0.0: multiplier 1.000 honest $127024  manipulated(D=1x S, t=1d) $65558   saved $61466
  term 30d slope 0.5: multiplier 1.000 honest $127024  manipulated(D=1x S, t=1d) $65558   saved $61466

== Why the band does not help: benefit saturates at t = period, cost is linear in t ==
  period    300s: t=0.25P: saved $47876 cost $32 | t=0.50P: saved $53822 cost $44 | t=1.00P: saved $61466 cost $68 | t=2.00P: saved $61466 cost $115
  period   3600s: t=0.25P: saved $47876 cost $163 | t=0.50P: saved $53822 cost $305 | t=1.00P: saved $61466 cost $591 | t=2.00P: saved $61466 cost $1162
  period  86400s: t=0.25P: saved $47876 cost $3445 | t=0.50P: saved $53822 cost $6869 | t=1.00P: saved $61466 cost $13719 | t=2.00P: saved $61466 cost $27417

== Attacker needs BORROWER role; but the same lever prices EVERY fixed borrow in the window: ==
   a $100M deposit held 1 day depresses the average for all borrowers for the next period.

=== HEADLINE ===
At the MAXIMUM averaging period (1 day), u=90%, a $100M par deposit held 24h cuts a $10M 30-day fixed premium from $127024 to $65558 (saves $61466) at a cost of $13719: 4x return. At the minimum (5 min) the cost is $68.
The band [5 min, 1 day] bounds the attack's DURATION, not its profitability; break-even D is < 1x supply at every period.
```

### `param_sensitivity.py`

```
param_sensitivity.py - permitted vs unsafe ranges (exact arithmetic where a number is given)

parameter (where)                          | permitted                                                              | OVERLAP     
----------------------------------------------------------------------------------------------------------------------------------
lt                                         | buffer < lt <= 1e27 (lt < ltv allowed)                                 | YES
   unsafe: lt > 1/(1+bonus) = 0.9804: healthiness>=1 while unrecoverableDebt>0 (solvency_waterfall); lt <= ltv+buffer: every borrow reverts Unhealthy / instant liquidation
   note:   Registry.initialize copies lt with NO check: lt=0 or lt<=buffer bricks lockedValue (div by zero) on every market created
   setter: BaseMarket.setLt
ltv                                        | ltv + buffer <= lt                                                     | no
   unsafe: none found (ltv=0 disables borrowing, safe)
   setter: BaseMarket.setLtv
buffer                                     | buffer < lt (may exceed lt - ltv, documented)                          | YES (documented as intended tightening)
   unsafe: buffer >= lt - ltv locks 100% of tranche capital (lockedValue $100M on $50M debt at buffer=0.3; $50000M at 0.799)
   note:   Registry.initialize: buffer >= lt => rayDiv(debt, 0) reverts in lockedValue -> Tranche.unlockedSupply/maxRedeem/claimable all revert
   setter: BaseMarket.setBuffer
targetHealth                               | >= 1.25e27, NO upper bound                                             | YES (economic)
   unsafe: maxLiquidatable denominator min = 0.15 ray (safe); first liquidation at h=1 clears 58%@TH1.25, 73%@TH1.50, 84%@TH2.00, 96%@TH5.00 of debt; rayMul overflow at TH > 4.6e+23 ray (absurd)
   note:   Registry.initialize: NO 1.25 floor. TH < (1+bonus)*lt => maxLiquidatable underflows => liquidate() reverts => no liquidation possible at all
   setter: BaseMarket.setTargetHealth
liquidationBonus                           | 0 <= bonus <= 0.1e27                                                   | YES
   unsafe: bonus = 0: liquidation never profitable (liquidation_cascade); bonus > 1/lt - 1 = 25.00% at lt 0.8: never; (1+bonus)*lt > 1 with lt > 0.9804: health lags
   note:   0 is permitted; combined with lt in (0.9804, 1] the pair is permitted and unsafe
   setter: IRM.setLiquidationBonus / initialize
base / slope0 / slope1                     | UNBOUNDED (only kink <= 1e27 checked)                                  | YES
   unsafe: rate >= 17207%/yr pushes a fully-drawn market (h=1.6) unhealthy within 1 day, >= 412989%/yr within 1 hour, >= 126199032%/yr within one 12s block; calculateCompoundedInterest reverts at rate > 3.40e+11 ray (1y gap) / 3.40e+11 ray (1s gap)
   note:   a rate above the revert point bricks _index() -> every borrow/repay/liquidate on floating markets reverts until slopes are lowered
   setter: IRM.setLiquiditySlopes
kink                                       | kink <= 1e27 (0 allowed, handled)                                      | no
   unsafe: none found
   setter: IRM.setLiquiditySlopes
termMultiplierSlope                        | UNBOUNDED                                                              | YES (grief/DoS of short terms only)
   unsafe: slope >= 2516 ray: a 1-day loan's premium >= its principal at 15% rate (availableCredit(term) -> ~0, borrow reverts InvalidPrincipal); rayMul overflow at slope > 7.7e+23 ray
   setter: IRM.setTermMultiplierSlope
underwriterRate                            | 0 <= rate <= maximumUnderwriterRate (init-only, 1e27 in deploy)        | YES (economic)
   unsafe: rate < (1+bonus)*p_default: underwriting negative EV (rate_sweep: 2.04% at 2% default risk); 0 is legal and documented
   note:   set by the borrowing side, not by governance or the underwriters
   setter: BaseMarket.setUnderwriterRate (MARKET OWNER) -> IRM.updateUnderwriterRate
marketMultiplier                           | [minimumMarketMultiplier, maximumMarketMultiplier] init-only ([1e27, 2 | no
   unsafe: none within the deploy band; band itself has NO setter so a bad init is permanent
   setter: BaseMarket.setMarketMultiplier (OWNER) -> IRM.updateMarketMultiplier
averagingPeriod                            | [5 min, 1 day]                                                         | YES (economic)
   unsafe: entire band: EMA depression is profitable at every period for L >= $10M (ema_manipulation)
   setter: IRM.setAveragingPeriod (falls to ADMIN, H9)
tranche weights                            | sum == 1e27; individual weight unbounded incl. 0; reverts if healthine | no (economic only)
   unsafe: weight 0 on a tranche = no premium but full slash exposure (junior-first) - accepted by code; clamp keeps rayMul half-up rounding from underflowing
   setter: BaseMarket.setTrancheWeights / setTranches / Registry.createTranche
fixedCreditLimit                           | UNBOUNDED (0 disables borrowing)                                       | no
   unsafe: none: creditLimit = min(fixed, variable) so variable always binds
   setter: BaseMarket.setFixedCreditLimit
maximumTermLimit / minimumTermLimit        | max != 0, min <= max, otherwise UNBOUNDED                              | YES (economic)
   unsafe: term > 2.9 years: whole-term premium >= principal at 35% carry (borrow of the limit yields ~0 principal); term*debt overflow at term > 4.6e+50 s (absurd). Long max terms also lock a manipulated EMA rate for the whole term
   setter: FixedMarket.setTermLimits
grace                                      | UNBOUNDED, init-only                                                   | YES (economic)
   unsafe: grace = 0: KEEPER may extendAdmin (skips health check, adds arrears premium) the instant a loan expires (H3)
   setter: FixedMarket.initialize (NO setter)
vestingPeriod                              | > 0, UNBOUNDED                                                         | YES
   unsafe: 1 second: premium vests instantly -> deposit-before-notifyPremium / claim / requestRedeem sandwich; very large: premium effectively never vests (locked in tranche)
   setter: Tranche.setVestingPeriod (owner)
minimum/maximumMarketMultiplier, maximumUnderwriterRate | min <= max checked; otherwise UNBOUNDED                                | YES
   unsafe: maximumUnderwriterRate huge => owner can set 1000%/yr underwriter rate: premium minted to tranches outpaces reserve (reserve_decay); no way to repair without upgrade
   setter: IRM.initialize (NO setter)
Registry lt/buffer/targetHealth            | ANY uint256                                                            | YES
   unsafe: lt <= buffer: lockedValue reverts (tranche exits bricked); targetHealth < (1+b)*lt: maxLiquidatable reverts; lt > 1e27: over-collateral credit. BaseMarket copies them unchecked at market creation
   setter: Registry.initialize (NO setter, NO validation)
----------------------------------------------------------------------------------------------------------------------------------
overlaps: 13 of 18 parameters

== numeric details ==
compoundedInterest revert thresholds: rate > 3.403e+11 ray (3.4e+13 %/yr) for a 1y gap; > 3.403e+11 ray for 30y; > 3.403e+11 ray for 1s
rate to push h=1.6 -> 1.0: 1 day 17207%/yr, 1 hour 412989%/yr, 1 block 126199032%/yr
maxLiquidatable perCleared at permitted extremes: TH 1.25, lt 1.0, bonus 10%: 0.15 ray (>0, safe by 0.15 as the NatSpec says)
healthiness lag threshold: lt > 0.9804 at bonus 2%; at bonus 10%: lt > 0.9091
termMultiplierSlope making 1-day loans cost >= principal at 15% rate: 2516 ray
  first liquidation at h=1: TH 1.25 lt 0.80 bonus 2%: 58% of debt
  first liquidation at h=1: TH 1.25 lt 0.95 bonus 2%: 89% of debt
  first liquidation at h=1: TH 1.25 lt 1.00 bonus 2%: 100% of debt
  first liquidation at h=1: TH 1.50 lt 0.80 bonus 2%: 73% of debt
  first liquidation at h=1: TH 1.50 lt 0.95 bonus 2%: 94% of debt
  first liquidation at h=1: TH 1.50 lt 1.00 bonus 2%: 100% of debt
  first liquidation at h=1: TH 2.00 lt 0.80 bonus 2%: 84% of debt
  first liquidation at h=1: TH 2.00 lt 0.95 bonus 2%: 97% of debt
  first liquidation at h=1: TH 2.00 lt 1.00 bonus 2%: 100% of debt

=== HEADLINE ===
13 of 18 governance parameters have a permitted range that overlaps an unsafe one. The three that break
accounting (not just economics): lt in (0.9804, 1] with bonus 2% (health lags unrecoverable debt); unbounded slopes
(>= 17207%/yr renders a full market liquidatable within a day; >3.4e+11 ray reverts the index); and Registry.initialize
accepting lt/buffer/targetHealth with no validation (lt<=buffer or TH<(1+b)lt bricks exits/liquidations on every market).
```
