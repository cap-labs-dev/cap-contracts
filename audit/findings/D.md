# WS-D — Markets, debt accounting, liquidation, write-off, rollover

Scope read end to end: `contracts/cap/market/BaseMarket.sol`, `FloatingMarket.sol`, `FixedMarket.sol`,
`contracts/interfaces/IBaseMarket.sol`, `IFloatingMarket.sol`, `IFixedMarket.sol`, the IRM entry points
they call (`indices`, `liquidityIndex`, `fixedRatesAfterMint`, `updateUnderwriterRate`,
`updateMarketMultiplier`, `liquidationBonus`, `termMultiplier`), `contracts/utils/MathUtils.sol`,
`WadRayMath.sol`, plus `Registry._configureMarketRoles` and `Stablecoin.{mintCreditBacked,
burnCreditBacked,recognizeBadDebt}` and `Tranche.slash` for the call targets.

Scratch tests: `audit/tests/scratch/D/D1..D9`. Run with
`FOUNDRY_TEST=audit/tests forge test --match-path 'audit/tests/scratch/D/*' -vv`.
Final run: **18 tests, 12 fail on current code, 6 pass** (the passes are contrast/verification
tests, noted per finding). Full output is quoted per finding below.

Role table used throughout (from `Registry._configureMarketRoles`): `extend` = market OWNER (not the
borrower), `extendAdmin` = KEEPER, `borrow`/`borrowMore` = BORROWER, `liquidate` = LIQUIDATOR,
`writeOff` = GUARDIAN, `setLt`/`setBuffer` = GUARDIAN, `setTargetHealth`/`setFixedCreditLimit`/
`setTermLimits` = GOVERNOR, `repay`/`chargePremium` = anyone.

---

### [MEDIUM] FloatingMarket's market multiplier is economically inert — it never changes what a floating borrower pays
**Location:** `contracts/cap/InterestRateModel.sol:164-166` (`liquidityIndex`), `contracts/cap/market/FloatingMarket.sol:54-65` (`setMarketMultiplier`), `:123-125` (`totalDebt`), `:219-231` (`_premium`)
**Impact:** Governance believes `setMarketMultiplier(2e27)` charges a floating market 2x the liquidity rate (IIRM natspec: "multiplier for a market's liquidity interest rate"; the setter is wired to the market owner and there is a whole re-indexing routine to make the change non-retroactive). It does nothing. `liquidityIndex(market) = I(t) * m` multiplies the *cumulative index* by a constant, and a floating market's accrual is the *ratio* of two readings of that index, `debt(t) = scaled * I(t) * m * U(t)`, with `scaled = P / (I(t0) * m * U(t0))`. `m` cancels. The re-indexing in `setMarketMultiplier` then also makes a mid-life change inert. Only `FixedMarket` (which multiplies the *rate* in `fixedRatesAfterMint`) responds to the multiplier. Lenders (stcUSD) are under-paid on every floating market that governance thinks it has priced up; the min/max multiplier band in the IRM is dead configuration for floating markets.
**Likelihood:** Certain — it is the arithmetic, no actor needed. Every floating market with multiplier != 1.
**Exploit path:** Not an attack; a mispricing. 1) Governance sets multiplier 2x on market B, 1x on market A. 2) Both borrow 1,000 for a year. 3) Both accrue 221.33 of liquidity premium, to the wei.
**Proof:** `audit/tests/scratch/D/D1_MultiplierInert.t.sol` — both floating tests FAIL, the fixed contrast PASSES:
```
[FAIL: 2x multiplier must charge materially more liquidity premium: 221332933560973813056 <= 331999400341460719584] test_floatingMultiplierChangesNothing()
  premium at multiplier 1x    : 221332933560973813056
  premium at multiplier 2x    : 221332933560973813056
[FAIL: 2x multiplier must accrue materially faster: 59495448826830583661 <= 84484727158243929258] test_floatingMultiplierSetMidwayAlsoChangesNothing()
  growth first 100d (1x) : 56323151438829286172
  growth next 100d  (2x) : 59495448826830583661     <- growth is just the higher index, not the multiplier
[PASS] test_fixedMultiplierWorks_forContrast()
  fixed premium 1x: 16438356164383561643
  fixed premium 2x: 32876712328767123287
```
**Recommendation:** Apply the multiplier to the *rate*, not the index: keep a per-market liquidity index in the IRM (`underwriterData`-style `RateData` per market) accrued at `liquidityRate * multiplier`, or accrue the market's own index in `FloatingMarket` from `liquidityRate() * multiplier` between charges. Second-order: `setMarketMultiplier`'s re-indexing becomes a genuine rate change and the "unchanged only to the nearest wei" drift it documents goes away, but every existing floating market's `lastLiquidityIndex` must be migrated on upgrade.
**Invariant broken:** none listed; new invariant N1 below.

---

### [MEDIUM] Premium keeps being minted against debt the protocol already knows is unrecoverable; the keeper's `extendAdmin` rolls compound it and the only brake is a discretionary GUARDIAN write-off (H3)
**Location:** `contracts/cap/market/FixedMarket.sol:105-110` (`extendAdmin`), `:285-299` (`_rollFromNow`, `_extend`), `:307-322` (`_chargePremiumForTerm`); `FloatingMarket.sol:195-209` (`_chargePremium`); `BaseMarket.sol:380-386` (`_writeOff`), `:438-480` (`_chargePremium`)
**Impact:** Once `totalDebt > recoverableDebt` (collateral cannot clear the debt even after a full liquidation) every further premium charge mints credit-backed cUSD that nothing will ever back: the borrower has defaulted and the collateral is exhausted. That cUSD is real and fungible — stcUSD stakers and tranche holders claim it and redeem it against the reserve at par, ahead of the depositors who eventually carry the `badDebt`. The write-off, when it finally comes, recognises the original shortfall **plus every premium minted since**. In the PoC 12 monthly keeper rolls on a $5,000 loan that was 80% unrecoverable mint **$1,650 of phantom yield** (+33%), of which the senior underwriter claimed $1,182 and cashed $327 of USDC out of the reserve before the write-off landed; recognised bad debt was $5,670 instead of $4,020. The floating market does the same with no role at all — twelve permissionless `chargePremium` pokes grew the shortfall from $4,020 to $5,631 (+40%). The H3 sub-questions: `extend` (OWNER) applies the health check at L101 to **both** branches including the expired `_rollFromNow` one, so the owner cannot roll an underwater loan; the borrower holds neither role and cannot roll at all; `extendAdmin` is the only unchecked path and its natspec says so deliberately ("an overdue loan must be rollable even when the market is already unhealthy").
Phantom yield after N rolls: `D_0 * (prod_i (1 + (term_i + arrears_i) * r_i / year) - 1)` where `r_i` is the liquidity+underwriter rate at each roll (~28%/yr here: 20% underwriter + ~8% liquidity at ~55% utilization, 31 days per roll => 2.4%/roll => 1.024^12 = 1.33).
**Likelihood:** No attacker needed. Preconditions: a market goes unrecoverable (a ~22% collateral drop from a max-ltv position at lt 0.8 / bonus 2%) and the guardian does not write off promptly. An honest keeper bot that "rolls overdue loans" (its documented job) makes it worse every term. Anyone holding stcUSD or tranche shares — including the keeper — profits from every roll.
**Exploit path (value extraction by a lender):**
1. Borrower draws the maximum 30-day fixed loan (P = 4,841, debt 5,000) against $10,000 of collateral; stcUSD/tranche holders hold their positions.
2. Collateral falls 90%: capital $1,000, `recoverableDebt` $980, `unrecoverableDebt` $4,020.
3. Keeper calls `extendAdmin(id, max)` at every `expiry + grace`, 12 times. Each roll charges `debt * 31 days * rate / year` on the whole debt and mints it.
4. Senior underwriter `claim()`s $1,182 of minted cUSD and `redeem()`s it: $327 of USDC leaves the reserve (haircut by the bad-debt curve, but still reserve that other depositors were counting on).
5. Guardian writes off: `badDebt` = $5,670, of which $1,650 exists only because of step 3.
**Proof:** `audit/tests/scratch/D/D2_RollDefaulted.t.sol`:
```
[FAIL: write-off should not exceed the shortfall that existed before the rolls: 4815722449171194887454 != 4019607843137254901959] test_H3_keeperRollsMintUnbackedYieldOnDefaultedLoan()
  debt at origination             : 4999999999999999999998
  unrecoverable debt before rolls : 4019607843137254901959
  rolls                           : 12
  debt after rolls                : 6650774693945761037667
  debt growth (all phantom)       : 1650774693945761037669
  creditBackedSupply growth       : 1650774693945761037669
  unrecoverable growth            : 1650774693945761037669
  cUSD minted to stcUSD           : 485736774884216358767
  cUSD minted to senior tranche   : 1106786023108467444957
  cUSD minted to junior tranche   : 58251895953077233945
  unlockedSupply (unchanged)      : 5000000000000000000000
  badDebt recognised at write-off : 5670382537083015939628
  of which minted by the rolls    : 1650774693945761037669
  senior underwriter claimed cUSD : 1182382840084594765910
  USDC redeemed from the reserve  : 327722752172773713736
[FAIL: shortfall should not compound while nobody can recover it: 5630659394151735795194 != 4019607843137254901961] test_H3_floatingAccruesOnUnrecoverableDebtWithoutAnyRole()
  unrecoverable before : 4019607843137254901961
  unrecoverable after  : 5630659394151735795194
  cUSD minted meanwhile: 1611051551014480893234
```
**Recommendation:** Make the brake structural rather than discretionary. Minimum: `extendAdmin` must revert (or be capped) while `unrecoverableDebt() > 0`, and `_chargePremium` should charge on `min(debt, recoverableDebt())` — premium on the unrecoverable slice is by definition a loss to cUSD holders, not income. Better: auto-recognise the shortfall (`recognizeBadDebt`) inside `_chargePremium` when `unrecoverableDebt() > 0` so the loss is booked the moment it exists and never grows. Second-order: charging only on the recoverable slice means a market that later recovers (price rebound) has under-accrued — acceptable, since the alternative is minting against nothing. The keeper's stated reason for skipping the health check (charging arrears rather than liquidating) is fine while `unrecoverableDebt == 0`; that is the bound to keep.
**Invariant broken:** I5 holds trivially (`unrecoverableDebt > 0`), which is exactly the problem: the system is honest about the shortfall but keeps paying yield out of it. I14 holds (premium minted == premium added to debt). New invariant N2 below.

---

### [MEDIUM] Fixed loan ids are never bounded by `loanCount`: a phantom id can be given an expiry, drawn on, and then re-termed by the next `borrow`, so the operator pair pays a 1-day premium for 30 days of exposure
**Location:** `contracts/cap/market/FixedMarket.sol:64-74` (`borrow` — `id = loanCount++; expiry[id] = block.timestamp + term` overwrites), `:77-86` (`borrowMore`), `:89-102` (`extend` — `expiry 0` reads as expired and rolls), `:105-110` (`extendAdmin`, same)
**Impact:** 95% of the liquidity and underwriter premium on a maximum-term loan is avoided. In the PoC $4,000 held for 30 days costs 6.54 cUSD instead of 131.51. The liquidity premium is owed to stcUSD holders who have no say in the market's configuration; the underwriter premium to tranche holders. `borrow` also silently merges debt onto an id the caller did not choose, so per-loan `expiry` is not a reliable record.
**Likelihood:** Needs one call from the market OWNER (`extend(loanCount, minTerm)`) or the KEEPER (`extendAdmin(loanCount, minTerm)` — `expiry 0 + grace <= now`), then two calls from the BORROWER. Owner and borrower are the two operator addresses of the same market and are routinely the same business; a keeper bot that accepts ids from an off-chain queue is also exposed. Cost: gas.
**Exploit path:**
1. `id = loanCount` (unused). Owner: `extend(id, 1 days)` — `expiry[id] == 0` so it takes the `_rollFromNow` branch; `debt[id] == 0` so the premium is zero. `expiry[id] = now + 1 day`.
2. Borrower: `borrowMore(id, self, 4_000e18)` — remaining term 1 day `>= minimumTermLimit`; pays 6.50 (1 day at the short-term multiplier).
3. Borrower: `borrow(self, 1e18, 30 days)` — `id = loanCount++` returns the same id, `expiry[id] = now + 30 days` overwrites. The 4,000 now has 30 days; total premium paid 6.54 vs 131.51 honest. Test confirms `borrowMore` still works at day 29.
**Proof:** `audit/tests/scratch/D/D9_PhantomLoanId.t.sol`:
```
[FAIL: 30 days of exposure must cost the 30-day premium: 6535159817351598172 < 131506849315068493150] test_reTermViaPhantomId_paysMinimumTermForMaximumTerm()
  honest 30-day premium on 4000: 131506849315068493150
  premium paid (1 day)         : 6502283105022831050
  premium paid in total        : 6535159817351598172
  premium avoided              : 124971689497716894978
```
**Recommendation:** `if (id >= loanCount) revert UnknownLoan();` in `borrowMore`, `extend`, `extendAdmin`, `repay`, `liquidate`, `writeOff`. Independently, `borrow` should assert `expiry[id] == 0 && debt[id] == 0` for the id it mints (belt and braces against any future path that seeds state). Second-order: none; no legitimate flow touches an id before `borrow` creates it.
**Invariant broken:** none listed; new invariant N3 below.

---

### [LOW] Tranches with zero collateral keep receiving the underwriter premium: routing is by `stakedSupply` (shares), not capital
**Location:** `contracts/cap/market/BaseMarket.sol:451-467` (`_chargePremium`, `if (ITranche(tranche).stakedSupply() == 0) continue;`)
**Impact:** After a full liquidation drains a tranche (and latches it `killed`), its shares still exist, so `stakedSupply() > 0` and it is paid its full weight of every subsequent premium while underwriting nothing. In the PoC the drained senior received $887 and the killed junior $47 over twelve rolls. Whoever the premium *should* go to (stcUSD, per the "inactive tranche" rule in the same function) is short-changed; combined with the previous finding this is minted, unbacked cUSD handed to the parties who just lost the collateral it was supposed to be paying for.
**Likelihood:** Every market that has been fully liquidated and keeps accruing (previous finding), or whose tranche has been slashed to near zero. No actor needed.
**Exploit path:** 1) Max-borrow, price falls 90%. 2) Liquidator takes everything (`totalCapital == 0`, junior `killed`). 3) Twelve keeper rolls. 4) Drained tranches hold $934 of fresh cUSD.
**Proof:** `audit/tests/scratch/D/D2_RollDefaulted.t.sol`:
```
[FAIL: a tranche with no capital should earn no premium: 887132370846222092005 != 0] test_H3_slashedToZeroTranchesStillReceivePremiumOnRoll()
  capital left after liquidation : 0
  premium minted to senior (0 capital): 887132370846222092005
  premium minted to junior (0 capital): 46691177412959057473
  junior killed: yes
```
**Recommendation:** Gate on `totalCapital() == 0` (or `killed`) in addition to `stakedSupply() == 0`; the leftover then follows the existing inactive-tranche route. Cross-reference WS-C / H12 (premium redirection).
**Invariant broken:** none listed; strengthens N2.

---

### [LOW] Floating debt reading drifts a wei either side of `creditBackedSupply` per operation; when it lands above, the loan can never be repaid in full (I3)
**Location:** `contracts/cap/market/FloatingMarket.sol:72-74` (`borrow`: `rayDiv` half-up), `:123-125` (`totalDebt`: `rayMul` half-up), `:54-65` (`setMarketMultiplier` reindex), `:226-230` (`_premium`, two half-up `rayMul`s per leg); `Stablecoin.sol:78` (`creditBackedSupply -= _amount`)
**Impact:** The exact identity is `sum(market.totalDebt()) == stablecoin.creditBackedSupply()` with **no** `badDebt` term (recognizeBadDebt lowers both sides in the same call; the plan's suggested "+ badDebt" adjustment is wrong). The fixed market keeps it to the wei. The floating market does not: `_floorReduction` made repay/liquidate/writeOff exact, but `borrow`, every `chargePremium`, and every `setMarketMultiplier` still round half-up on both the scaled and the reading side, so the identity drifts +/-1 wei per operation (random walk, so the "cannot accumulate" claim in `setMarketMultiplier`'s comment is false in the strict sense; it grows as sqrt(n)). The repo's own test only asserts `totalDebt <= creditBackedSupply` (one direction, 20 iterations). When the reading is **above** credit, `repay(type(uint256).max)` reverts in `burnCreditBacked` (`creditBackedSupply -= amount` underflows) and paying `debt - 1` leaves scaled dust that can never be cleared either: 10 wei of debt, 9 wei of credit, permanently. Consequences are dust-sized (a few wei of `lockedValue`, non-zero utilization, a market that can never read empty) — but it is the invariant the plan calls I3, and the same underflow is what makes the reentrancy finding below system-wide rather than local.
**Likelihood:** Reached by ordinary use; the fuzz finds it in the first seed. The deterministic test reaches it in 2 borrows at a grown index.
**Exploit path:** None (no profit). Liveness: the last borrower to repay in the system cannot clear the last wei.
**Proof:** `audit/tests/scratch/D/D3_I3Exact.t.sol`:
```
[FAIL: I3 must hold exactly: 98399519918632223860133 != 98399519918632223860131; ...] testFuzz_I3_floatingDebtEqualsCreditBackedSupply(uint256) (runs: 0 ...)
  worst (creditBackedSupply - totalDebt): -2
[FAIL: the loan must be clearable in full: 10 != 0] test_fullRepayRevertsWhenReadingExceedsCredit()
  index: 10482336806351969674908819970
  totalDebt         : 10543336806351969676740
  creditBackedSupply: 10543336806351969676739
  full repay reverted with: 0x4e487b71...0011      <- Panic(0x11) arithmetic underflow
  debt left after repay(debt - 1): 10
  creditBackedSupply left        : 9
  second full repay reverted with: 0x4e487b71...0011
```
**Recommendation:** Track the market's own minted-minus-burned counter (`creditIssued`) alongside `scaledDebt` and have `totalDebt()` return `min(reading, creditIssued)`, or mint/burn the *difference in reading* rather than the requested amount on `borrow` and premium charges (the same trick `_floorReduction` already uses for reductions). For the full-repay path, clamp the burn at `creditBackedSupply` is wrong (it hides the drift); the fix is on the mint side. `setMarketMultiplier` should floor `scaled` rather than round half-up so its drift is one-directional and bounded by the number of governance calls.
**Invariant broken:** I3.

---

### [LOW] `FloatingMarket.liquidate` writes `scaledDebt` after the external slash; a collateral with a transfer hook lets the liquidator re-enter and drain the entire tranche while debt falls once
**Location:** `contracts/cap/market/FloatingMarket.sol:90-103` (`liquidate`: `_liquidate` at L101, `scaledDebt = remainingScaled` at L102), `BaseMarket.sol:361-367` (`_liquidate` slash loop -> `Vault.withdraw` -> `safeTransfer(recipient)`)
**Impact:** The inner call sees the un-reduced `totalDebt` (health gate passes, `maxLiquidatable` recomputed against already-reduced capital), burns and slashes again, and its own `scaledDebt` write is overwritten by the outer call's stale `remainingScaled`. In the PoC one call clears $3,341 of debt, burns $5,882 of cUSD, and takes the whole $6,000 of collateral; afterwards `sum(totalDebt) = 41,659 > creditBackedSupply = 39,118` — the $2,541 gap lands on an **unrelated** market's borrower, who now cannot repay in full (previous finding's underflow). The liquidator's own take is still only the 2% bonus, so this is destructive rather than lucrative for them; the tranche loses $2,659 of collateral for no debt reduction. The `FixedMarket` path does not overwrite (`debt[id] -= repaid` is additive) but still over-liquidates past target because the inner health gate reads stale `_totalDebt`.
**Likelihood:** Needs the LIQUIDATOR role (trusted) **and** a hooked collateral (ERC-777/1363; `IVault.sol:9-13` pushes token safety to listing policy). Both are governance choices, hence Low despite the impact.
**Exploit path:** 1) Market with hooked collateral, max-borrowed, price falls 40%. 2) Liquidator contract calls `liquidate(self, max)`; in the hook, re-enters `liquidate(self, max)` (depth 3). 3) State as above.
**Proof:** `audit/tests/scratch/D/D8_LiquidateReentry.t.sol`:
```
[FAIL: I3: debt cleared must equal cUSD burned: 3341013824884792626728 != 5882352941176470588235] test_reenteredLiquidationOverSlashesAndBreaksI3()
  maxLiquidatable (single call): 3341013824884792626728
  debt cleared          : 3341013824884792626728
  cUSD burned           : 5882352941176470588235
  collateral value taken: 6000000000000000000000
  health after          : 0
  sum of market debt    : 41658986175115207373272
  creditBackedSupply    : 39117647058823529411765
```
(With a single market the inner burn underflows `creditBackedSupply` and reverts harmlessly — the test needs a second market with outstanding debt, as any real deployment has.)
**Recommendation:** Store `scaledDebt = remainingScaled` **before** `_liquidate` (the comment explains it is stored last so the health gate and cap "see the debt as it stands" — pass `debt` in explicitly instead of re-reading `totalDebt()` inside `_liquidate`/`maxLiquidatable`), and add a reentrancy guard on `liquidate` in both markets.
**Invariant broken:** I3 (system-wide), I16 (liquidation against a stale reading).

---

### [LOW] `FloatingMarket.borrow` has no post-borrow health assertion; once GUARDIAN drops `lt` below `ltv`, a single borrow lands the market liquidatable and the tranches pay the bonus (I8)
**Location:** `contracts/cap/market/FloatingMarket.sol:68-77` (`borrow`), `BaseMarket.sol:82-91` (`setLt` — "Dropping lt below ltv is still allowed"), contrast `FixedMarket.sol:202`
**Impact:** `variableCreditLimit = ltv * activeCapital` exceeds `debtLiquidationThreshold = lt * totalCapital`. Borrower draws to the limit, health reads 0.8, `maxLiquidatable` is $2,672 on a $5,000 draw, and the liquidator collects 2% of it from the tranches on a position that never should have opened. A borrower/liquidator pair nets `bonus * maxLiquidatable` from the underwriters using the borrowed cUSD itself as the repayment. `FixedMarket._borrow` asserts health after charging for exactly this reason ("that chain leans on invariants owned elsewhere... so it is asserted here rather than assumed"); the floating market assumes.
**Likelihood:** Requires GUARDIAN to set `lt < ltv` first (a documented, permitted action, and a plausible emergency one). Then the BORROWER alone.
**Exploit path:** 1) `setLt(0.4e27)` with `ltv = 0.5e27`. 2) `borrow(max)` = 5,000 against $10,000: health 0.8. 3) Liquidator (colluding or not) liquidates $2,672, tranches lose $2,725.
**Proof:** `audit/tests/scratch/D/D4_FloatingBorrowUnhealthy.t.sol`:
```
[FAIL: a borrow must never leave the market liquidatable: 800000000000000000000000000 < 1000000000000000000000000000] test_floatingBorrowLandsLiquidatable_whenLtBelowLtv()
  drawn      : 5000000000000000000000
  healthiness: 800000000000000000000000000
  maxLiquidatable: 2672209026128266033254
[PASS] test_fixedBorrowRefuses_forContrast()      <- FixedMarket reverts Unhealthy()
```
**Recommendation:** Mirror `FixedMarket`: `if (healthiness() < 1e27) revert Unhealthy();` at the end of `FloatingMarket.borrow`. Alternatively cap `availableCredit()` at `debtLiquidationThreshold() - totalDebt()`.
**Invariant broken:** I8 (via `setLt`), and the borrow-side half of I5.

---

### [LOW] Registry seeds `lt`/`buffer`/`targetHealth` into every market unvalidated and has no setters; out-of-band values brick liquidation or every tranche withdrawal until each market is repaired individually
**Location:** `contracts/cap/Registry.sol:120-122` (`initialize`), `contracts/cap/market/BaseMarket.sol:53-55` (`__BaseMarket_init`), `:245-255` (`maxLiquidatable`: `targetHealth - perDebt*lt` underflows), `:270-272` (`lockedValue`: `rayDiv(lt - buffer)` reverts on zero)
**Impact:** `targetHealth = 1e27` (below the `setTargetHealth` floor) with `lt = 1e27`, bonus 0.1e27 makes `maxLiquidatable()` panic, so `liquidate` reverts on every market until GOVERNOR calls `setTargetHealth` per market. `lt == buffer` makes `lockedValue()` revert, so `Tranche.unlockedSupply()` and therefore every tranche redemption reverts until GUARDIAN calls `setLt`/`setBuffer` per market. Both are recoverable and the shipped `DeployInfra.sol:88-90` hardcodes valid values (0.8 / 0.1 / 1.25), so this is a latent deployment hazard, not a live one. WS-F/E own H8; this is the market-side consequence.
**Likelihood:** Misconfigured deployment or a future `Registry` upgrade that adds setters without validation.
**Exploit path:** n/a (misconfiguration).
**Proof:** `audit/tests/scratch/D/D5_RegistrySeeds.t.sol`:
```
[FAIL: maxLiquidatable must not revert on registry-seeded parameters] test_targetHealthBelowFloor_bricksLiquidation()
[FAIL: unlockedSupply must not revert on registry-seeded parameters] test_ltEqualsBuffer_bricksTrancheWithdrawals()
```
**Recommendation:** Validate in `Registry.initialize` with the same predicates the market setters use (`lt <= 1e27`, `buffer < lt`, `targetHealth >= 1.25e27`), and have `__BaseMarket_init` route through the internal setter logic rather than raw assignment.
**Invariant broken:** none; the plan's note at H8.

---

### [INFORMATIONAL] Arrears on a rolled loan are priced at the cheapest point of the term curve
**Location:** `FixedMarket.sol:295-299` (`_extend` -> `_chargePremiumForTerm(id, debt, extension, 0)`), `:219-226` (`termUtilization = extension / maximumTermLimit`), `InterestRateModel.sol:192-197` (`termMultiplier` returns 1 ray for `>= 1 ray`)
The term multiplier is applied to the *length of the extension*, arrears included. A 1-day live extension pays `1 + slope * 29/30` (2.93x at slope 2); 29 days of arrears plus a 1-day roll is 30/30 and pays 1x. Measured: 1.63/day live vs 0.56/day rolled (`D7_FixedSizing.t.sol::test_arrearsArePricedAtTheCheapestTermMultiplier`, passes — it is a print). Whether a borrower who let the loan lapse should pay the *long-term* rate for the lapse is a policy question; noting it because the borrower can induce a roll simply by not repaying, so the cheap rate is reachable by inaction. Could not demonstrate a net gain over paying on time (the arrears are charged in full), so Informational.

### [INFORMATIONAL] Liquidation mechanics — verified, with observations
- (a) `maxLiquidatable` lands health on `targetHealth` to within 1e-12 relative across 512 fuzzed (price, target in [1.25, 3], bonus in [0, 0.1]) cases in the recoverable regime (`D6_MaxLiquidatable.t.sol`, passes). Algebra checked: the derivative of health w.r.t. amount repaid has the sign of `C - p*D`, independent of the amount, so in the regime `D > C/p` every liquidation *lowers* health and the cap at `recoverableDebt` drains the collateral to zero. The comment's claim survives. The `D == C/p` boundary liquidates the whole debt (health reads 1 ray by the `debt == 0` convention).
- (b) Profitability: the liquidator burns at par and receives `1 + bonus` of collateral at the **oracle** price. With a 2% bonus, any oracle overstatement above 2% (stale-high feed, H4) makes liquidation a loss and it stalls; WS-E owns the oracle. Independently, in the unrecoverable regime the last liquidation can receive slightly less than `1 + bonus` (clamped at the tranche's balance, `Tranche.slash:87-90`), bounded by the 1-wei rounding between `recoverableDebt` (half-up) and `toSlash` (half-up).
- (c) Dust liquidations extract *less* than one full one: `_liquidate` reverts `Healthy()` at health >= 1 ray, so partials stop at 1.0 while a single call sized at `maxLiquidatable` goes to 1.25 (measured: 200 x 10 partials = $2,000 vs one call = $4,263). No dust-extraction edge.
- (d) `FixedMarket.liquidate(id, ...)` gates on **market** health and the liquidator picks the id. Collateral is pooled and there is exactly one borrower role per market (`Registry._createMarket` grants `borrowerRole` to one address), so "a healthy loan is liquidated because another loan is bad" is the same borrower either way. Note that liquidating a loan burns debt that already includes its prepaid, unearned premium — the lenders keep the full term's premium on a loan that no longer runs. Design choice; no refund path exists.
- (e) LIQUIDATOR dependency (H11): if the single liquidator is absent, nothing clears debt and the shortfall grows at the market rate — measured +40% in 12 months on the unrecoverable slice at ~28%/yr (D2, floating). The roll/accrual finding above is what makes absence expensive; with it fixed, absence merely delays.

### [INFORMATIONAL] Write-off forgives the borrower on-chain; the guardian's choice of loan is economically irrelevant
`FixedMarket.writeOff(id)` reduces `debt[id]`, and `FloatingMarket.writeOff` reduces `scaledDebt`. The borrower's obligation is reduced by the written-off amount permanently; if collateral later recovers or the borrower resumes paying, nothing routes their repayments to `badDebt` (only GOVERNOR's `coverBadDebt` from its own balance does). Since every fixed loan in a market belongs to the same borrower, which `id` the guardian picks moves nothing except which `expiry` survives. Could not demonstrate a borrower-forced write-off (the borrower cannot make the guardian act), so Informational; but the on-chain forgiveness is worth stating in the trust model.

### [INFORMATIONAL] Third-party `repay` — no grief found
`repay` burns from `msg.sender` only. A stranger can only reduce someone else's debt with their own cUSD. It can front-run a liquidation to shrink `maxLiquidatable` (reducing the liquidator's take, benefiting the tranches) and it lowers utilization — both gifts. `_floorReduction` rejects sub-unit amounts, so no 1-wei spam. `chargePremium` spam only re-rounds half-up per call (unbiased); no directional gain.

### [INFORMATIONAL] `extend` on a live loan panics after `setTermLimits` shrinks the maximum
`FixedMarket.sol:94`: `maximumTermLimit - (previousExpiry - block.timestamp)` underflows when an existing loan's remaining term exceeds the new maximum. Reverts with Panic(0x11) rather than `InvalidTerm`; self-heals as time passes. Style-level; noted because the panic is indistinguishable from a bug in monitoring.

### [INFORMATIONAL] Fixed premium sizing — verified
`_principalWithin` (floor) vs `_premium` (half-up then floor) was fuzzed at 1,024 runs over limits down to 1 wei, terms across the band, slope1 up to 3 ray and underwriter rate up to 100% (`D7_FixedSizing.t.sol::testFuzz_debtNeverExceedsLimit`, passes): `debt <= limit` and `healthiness >= 1 ray` held. `chargeableDebt * term` cannot overflow at any plausible debt (`< 1e50` needed). The L202 health assertion is reachable only when `setLt` has put `lt < ltv` (as in the Floating finding); it is sufficient for the fixed market. `borrowMore` cannot extend exposure: it charges the new principal for the remaining term at that term's (dearer) multiplier and leaves `expiry` alone.

---

## Rounding sites (direction, who it favours)
| Site | Op | Direction | Favours |
|---|---|---|---|
| `FloatingMarket.borrow:72` `rayDiv(index)` | scaled principal | half-up | random +/-1 wei on reading vs mint (I3 drift) |
| `FloatingMarket.totalDebt:124` `rayMul(index)` | reading | half-up | as above |
| `FloatingMarket._premium:226-230` two `rayMul` per leg | premium | half-up each | random; minted == added to debt only to +/-1 wei |
| `FloatingMarket._floorReduction:186` `mulDiv` floor | repay/liquidate/writeOff | floor | payer never over-charged; exact vs credit (correct) |
| `FloatingMarket.setMarketMultiplier:60` `rayDiv` | reindex | half-up | random walk, +/-1 wei per call |
| `FixedMarket._premium:339-340` `rayMul` then `/ YEAR` | premium | half-up then floor | borrower (net floor) |
| `FixedMarket._principalWithin:264` `mulDiv` floor, `(term*rate)/YEAR` floor | sizing | floor | credit limit (principal never over-sized) |
| `BaseMarket.maxLiquidatable:250-251` `rayMul`/`rayDiv` | liquidatable | half-up | liquidator by <=1 wei |
| `BaseMarket.recoverableDebt:259` `rayDiv(perDebt)` | recoverable | half-up | liquidator/writer-off by <=1 wei |
| `BaseMarket._liquidate:359` `rayMul(perDebt)` | slash value | half-up | liquidator by <=1 wei (clamped by tranche balance) |
| `BaseMarket._chargePremium:460` `rayMul(weight)` per tranche, clamp | split | half-up, leftover to senior | senior tranche |
| `Tranche.slash:85,89` `value*unit/price`, `total*price/unit` | assets out | floor | tranche (liquidator loses <=1 unit) |
| `Tranche.totalCapital:282` `assets*price/unit` | capital | floor | conservative (lower capital) |
| `IRM._premium` linear/compound | index | binomial approx, under | borrower |

## Invariants
Broken (with tests):
- **I3** `sum totalDebt == creditBackedSupply` — broken by +/-wei drift in FloatingMarket (D3) and grossly by liquidate re-entry (D8). Note for the invariant suite: the identity has **no** `badDebt` term; write-offs move both sides together. Test mints via `_mintStable` must be tracked separately.
- **I8** `variableCreditLimit <= debtLiquidationThreshold` — broken by `setLt` below `ltv` (documented), and the floating market has no backstop (D4).
- **I16** accrual-before-action — the reentrant inner `liquidate` acts on a stale `totalDebt` (D8).
- **I5** holds, but trivially, in the state that matters (unrecoverable > 0), and that is where phantom yield is minted (D2).

New invariants the code implies that the plan missed:
- **N1** For a floating market, `(debt(t2)/debt(t1))` over an interval with no borrows/repays must equal `(1 + underwriterGrowth) * (1 + liquidityGrowth * marketMultiplier)`; today the multiplier term is identically 1.
- **N2** No credit-backed cUSD is minted as premium while `unrecoverableDebt() > 0` (or: `badDebt` recognised at write-off never exceeds the `unrecoverableDebt` that existed at the first block it became positive). Corollary: a tranche with `totalCapital() == 0` receives no premium.
- **N3** For every `FixedMarket` id-taking function, `id < loanCount`; and `borrow` never observes `expiry[id] != 0 || debt[id] != 0` for the id it mints.
- **N4** After any single `liquidate` call (including re-entrant), `debtCleared == cUSDburned` and `debtCleared <= maxLiquidatable()` as read before the call.
- **N5** Registry-seeded `lt`, `buffer`, `targetHealth` satisfy the market setters' own predicates.

## Appendix: gas & style
- `FloatingMarket.premiumIndices` and `index()` both branch on `lastPremiumUpdate == block.timestamp`; `index()` could call `premiumIndices()` unconditionally (it already handles the same-block case).
- `BaseMarket.totalDebt()` is `virtual` with an empty body rather than `abstract`; a market that forgets to override silently reads zero debt. Make it abstract.
- `FixedMarket.extend/extendAdmin/borrowMore` accept ids beyond `loanCount` (see Medium finding); even after the fix, an `UnknownLoan` error would make the revert legible.
- `_rollFromNow` uses `block.timestamp - previousExpiry` where `previousExpiry` can be 0 (never-borrowed id): arrears of ~55 years, harmless only because `debt[id] == 0`.
- `FixedMarket.sol:94` arithmetic underflow instead of `InvalidTerm` when `maximumTermLimit` has been lowered under a live loan.
- `IFixedMarket.extendAdmin` natspec ("an overdue loan must be rollable even when the market is already unhealthy") documents the H3 behaviour as intended; the finding above argues the bound should be `unrecoverableDebt == 0`, not health.
