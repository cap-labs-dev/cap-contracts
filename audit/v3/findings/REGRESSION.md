# Workstream R — Regression of round-1 and round-2 findings on HEAD `a843c1d`

Scope: every open round-1 finding (H-1, H-2, M-1..M-5, 15 Lows + L-8 partial + L-15 regressed), every round-2 finding (R2-H1, R2-H2, R2-M1, R2-M2, R2-L1..L7), and a re-check of the four items round 2 recorded as fixed (C-1, L-2, L-7, L-17). Prior PoCs were ported, not edited; where the prior PoC no longer applies the minimal test that demonstrates the original claim on the new code was written. Assertion convention is unchanged from rounds 1-2: **every test asserts the desired property, so `[FAIL]` = the finding reproduces, `[PASS]` = the property holds.** Tests whose only purpose is to characterise a residual are named `*residual*` / `*narrowing*` and are called out as such.

Run (the coordinator asked for per-directory `FOUNDRY_TEST`; other agents' half-written files break the wide compile):
```
FOUNDRY_TEST=audit/v3/tests/scratch/R1 forge test --match-path 'audit/v3/tests/scratch/R1/*' -vv   # 26 suites: 41 passed, 27 failed (68)
FOUNDRY_TEST=audit/v3/tests/scratch/R2 forge test --match-path 'audit/v3/tests/scratch/R2/*' -vv   #  6 suites: 12 passed,  6 failed (18)
```
Full logs: `audit/v3/tests/scratch/R1/run.log`, `audit/v3/tests/scratch/R2/run.log`. Fuzz runs are real (256 each: `testFuzz_debtNeverExceedsCredit`, `testFuzz_L9_floatingMultiplierMonotone`, `testFuzz_emaPathIndependent`).

Fix attribution is by `git log -S` on `contracts/` (commits between round 2 and HEAD: `e4a7b93` Fix Highs from 11/9 audit, `142ec65` Cleanup repo for audit, `2429b6c` Refactor market multiplier and fix ERC7540, `a843c1d` Fix rounding issues).

## 1. Status table

Severity "now" is re-assessed under the round-3 stance (curators, market owners, allocators, borrowers are third parties).

| ID | Round | Severity then | Severity now | Status | Test file (`audit/v3/tests/scratch/`) | One-line evidence |
|---|---|---|---|---|---|---|
| H-1 stale Underwriter mark | 1 | High | **High** | **OPEN** | `R1/H1_StaleMark.t.sol` 0/3 | exiter paid 500.0 vs fair 415.0; stayer −85.0 (20%); no permissionless re-mark; NatSpec now calls the lag intentional |
| H-2 queue out-of-order | 1 | High | Low (residual) | **FIXED** (drain) / **CHANGED** (view) | `R1/H2_OutOfOrderSettlement.t.sol` 3/4 | claim while locked reverts, health stays 1.12; residual: Σ claimable 300 > unlocked 261 (view), second claimant reverts |
| M-1 stale feed bricks market | 1 | Medium | **Medium** | **OPEN** (narrower) | `R1/M1_OracleBricksLiquidation.t.sol` 3/4 | `InvalidPrice()` from healthiness/maxLiquidatable/writeOff/liquidate/senior.maxRedeem; only *empty* dead-feed tranche or *debt-free* market escape |
| M-2 EMA park | 1 | Medium | **Medium** | **OPEN** | `R1/M2_EmaManipulation.t.sol` 1/4 | 1 h park: premium 8,966 → 6,779 (−24.4%), 19× cost; same-block flash: no discount (NatSpec claim survives) |
| M-3 JIT premium | 1 | Medium | **Medium** | **OPEN** | `R1/M3_JitPremium.t.sol` 0/3 | 19.7% of a 30-d fixed premium for 6 h; 43% at 24 h floating; 50% on `report`; 100% instant exit |
| M-4 recognition lag | 1 | Medium | **Medium** | **OPEN** | `R1/M4_RecognitionLag.t.sol` 0/3 | par exit 10,000 vs 8,182 on the curve; new GUARDIAN `recognizeBadDebtInReserve` is equally discretionary |
| M-5 loan-id reuse | 1 | Medium | — | **FIXED** `a843c1d` | `R1/M5_LoanIdReuse.t.sol` 6/6 | `LoanNotFound`/`LoanClosed` on every id-taking function; honest re-term charges full term |
| R2-H1 curator drain | 2 | High | **High** | **OPEN** | `R2/R2_H1_CuratorDrain.t.sol` 2/4 | 1,000e18 (100%) drained via `addTranche(fake)`; a WHITELISTED third party builds its own curator and drains 500e18 |
| R2-H2 invisible Aera loss | 2 | High | Medium (see §2) | **CHANGED** | `R2/R2_H2_AeraLoss.t.sol` 3/4 | redeemer paid 500 vs fair 450 after a 100 loss; `recognizeBadDebtInReserve` (GUARDIAN) now books it without touching credit; `unlockedSupply` capped by on-hand |
| R2-M1 owner strips junior | 2 | Medium | Low (residual) | **FIXED** `e4a7b93` | `R2/R2_M1_OwnerSetTranches.t.sol` 3/4 | `setTranches` REGISTRY-only; owner can neither strip nor reorder; residual: weight 0 accepted on a locked tranche |
| R2-M2 Wrapper inflation | 2 | Medium | Info (residual) | **FIXED** `142ec65` | `R2/R2_M2_WrapperInflation.t.sol` 3/3 | 1 wei refused (`DepositBelowSeed`); victim 408 shares vs fair 407; attacker 1/1001 of pot; deploy seeds 1e18 |
| L-1 premium rounding drift | 1 | Low | — | **FIXED** `a843c1d` | `R1/L1_PremiumDrift.t.sol` 2/2 | gap 0 wei after 365 daily accruals; full repay and write-off succeed; fuzz 256 |
| L-3 floating borrow unhealthy | 1 | Low | — | **FIXED** `2429b6c` | `R1/L3_FloatingBorrowUnhealthy.t.sol` 2/2 | credit sized off `min(ltv, lt)`; draw lands health exactly 1e27 |
| L-4 registry seeds unvalidated | 1 | Low | — | **FIXED** `2429b6c` | `R1/L4_RegistryDefaults.t.sol` 4/4 | `InvalidLt` on lt ≤ buffer / lt > 1; `InvalidTargetHealth` on 1.0 |
| L-5 `lt > 1/(1+bonus)` | 1 | Low | Low | **OPEN** | `R1/L5_LtAboveBonusBound.t.sol` 0/2 | lt 0.99: health 1.0011, unrecoverable 7.65, `liquidate` → `Healthy()`, GUARDIAN writes off a "healthy" market |
| L-6 unbounded IRM slopes | 1 | Low | Low | **OPEN** | `R1/L6_IrmBounds.t.sol` 1/2 | base 1e37 accepted; after 30 d index/deposit/mint revert and `setLiquiditySlopes(sane)` REVERTS |
| L-8 deploy path (partial) | 1 | Low | — | **FIXED** `142ec65` | `forge script` (no test) | compiles, on build path, CreateX (no `address(this)` nonce math), Oracle+adapter deployed; stops only at `CreateX missing` in-memory |
| L-9 floating multiplier inert | 1 | Low | — | **FIXED** `2429b6c` | `R1/L9_MultiplierInert.t.sol` 4/4 | 1×: 221.3 vs 2×: 491.7 over a year; fuzz monotone 256 |
| L-10 phantom yield on defaulted debt | 1 | Low | Low | **OPEN** | `R1/L10_RollDefaulted.t.sol` 0/2 | 12 rolls mint 1,650.8 phantom, badDebt 5,670 vs 4,020 pre-roll; 327.7 USDC cashed from reserve |
| L-11 zero-capital tranche earns | 1 | Low | — | **FIXED** `a843c1d` | `R1/L11_ZeroCapitalWeight.t.sol` 2/2 | wiped junior earns 0 (`_earnsPremium` checks `totalCapital`); dust case is I39 (WS-D) |
| L-12 kill latch on emptied junior | 1 | Low | Low | **OPEN** | `R1/L12_KillLatch.t.sol` 1/2 | 1000 dead shares > 0 → `killed`, `maxDeposit 0`, re-deposit reverts |
| L-14 queued shares forfeit premium | 1 | Low | Low | **OPEN** | `R1/L14_QueueForfeitsPremium.t.sol` 0/1 | staked 0 with 714e18 locked; 30 d premium to tranche 0, to cUSD 8.29; still slashed 714 → 612; no cancel |
| L-15 / R2-L2 circuit breaker | 1/2 | Low | Low | **OPEN** (documented as deliberate) | `R1/L15_CircuitBreaker.t.sol` 0/2 | floor 1.0 served, secondary 0.0001 never consulted; adapter NatSpec now says clamp checks are out of scope |
| L-16 future stamp never stale | 1 | Low | Low | **OPEN** | `R1/L16_FutureStamp.t.sol` 1/2 | 2000 served 5 y after last write; secondary 1500 unused |
| L-18 Vault mint-before-pull | 1 | Low | — | **FIXED** `2429b6c` | `R1/L18_VaultCallback.t.sol` 1/1 | hook sees balance 0, supply 100e18; mid-flight withdraw refused |
| L-19 bonus 0 permitted | 1 | Low | Low | **OPEN** | `R1/L19_L20_L21_Params.t.sol` 0/3 | `setLiquidationBonus(0)` accepted |
| L-20 first-liquidation cliff | 1 | Low | Low | **OPEN** (design) | same | 57.97% of debt cleared at health 0.9984; junior wiped and killed in one call |
| L-21 owner sets underwriter rate to 0 | 1 | Low | Low → **consider Medium** | **OPEN** | same | owner zeroes the rate with 714e18 of underwriter shares locked; no floor, no notice |
| R2-L1 invest breaks views | 2 | Low | — | **FIXED** `e4a7b93`/`2429b6c` | `R2/R2_H2_AeraLoss.t.sol::test_R2L1_*` | `unlockedSupply`/`maxInstantRedeem` = on-hand 400; over-claim refused by `ExceededMaxRedeem`, not a failed transfer |
| R2-L3 oracle source checks | 2 | Low | Low | **CHANGED** (half fixed `142ec65`) | `R2/R2_L3_OracleSourceChecks.t.sol` 1/2 | raw feed as payload refused (`_read` needs 64 bytes); same feed twice → 4,000,000 (p²) accepted |
| R2-L4 `claim` zeroes before clamp | 2 | Low | Low | **OPEN** (code reading) | — | `PremiumVesting.sol:142-155` unchanged: `_settlePremium` zeroes `pending/debt`, then clamps to `balanceOf(this)` |
| R2-L5 opt-in economics | 2 | Low | Low | **OPEN** (design) | `R2/R2_L5_OptInEconomics.t.sol` 0/1 | 1 opted-in wei takes 6.629 of a 6.630 pot; 1000e18 un-opted earns 0 and is slashable |
| R2-L6 reserveVault fixed | 2 | Low | Info (residual) | **FIXED** `142ec65` | `R2/R2_H2_AeraLoss.t.sol::test_R2L6_*` | GOVERNOR `setReserveVault`; residual: no `invested == 0` gate, recall from the new vault reverts |
| R2-L7 deploy residuals | 2 | Low | — | **FIXED** `142ec65` | `forge script` (no test) | see L-8 |
| C-1 oracle decimals | 1 (fixed r2) | Critical | — | **still FIXED** | `R1/C1_OracleDecimals.t.sol` 4/4 | feed 2000e8 → oracle 2000e18; capital 2,000,000e18; seize = repaid·1.02 to 1e-15 |
| L-2 reentrant liquidate | 1 (fixed r2) | Low | — | **still FIXED** | `R1/L2_ReentrantLiquidate.t.sol` 2/2 | inner call refused `ReentrancyGuardReentrantCall`; burned 100, received 204; I3 holds |
| L-7 role-0 selectors | 1 (fixed r2) | Low | — | **still FIXED** | `R1/L7_RoleTable.t.sol` 2/2 | every restricted selector on Registry-wired instances resolves to its named role; only UUPS/beacon upgrades are ADMIN(0), by design |
| L-17 EMA regime | 1 (fixed r2) | Low | — | **still FIXED** | `R1/L17_EmaRegime.t.sol` 2/2 | quiet vs 12-s accrual differ by 2 wei on 2.13e24; 256-run path-independence fuzz |

Totals on HEAD: **OPEN 17** (H-1, M-1, M-2, M-3, M-4, R2-H1, L-5, L-6, L-10, L-12, L-14, L-15/R2-L2, L-16, L-19, L-20, L-21, R2-L4, R2-L5 — counting L-15/R2-L2 once), **CHANGED 3** (H-2 → Low residual, R2-H2, R2-L3), **FIXED 14** (M-5, R2-M1, R2-M2, L-1, L-3, L-4, L-8, L-9, L-11, L-18, R2-L1, R2-L6, R2-L7 + the four round-2 fixes re-confirmed), **REGRESSED 0**.

## 2. Per-finding detail

### H-1 — Underwriter redeems at a stale post-slash mark — OPEN, High
**HEAD:** `contracts/cap/Underwriter.sol:243-245` (`totalAssets = idle + totalDebt`), `:187-203` (`_mark`, runs only from `allocate`/`deallocate`/`deallocateAsync`/`finalizeDeallocateAsync`/`_report`), `:265-267` (`unlockedSupply = _quoteWithdraw(idle)` at the cached price). `report` is KEEPER (Registry.sol:506-508); `allocate/deallocate*` are the allocator role. HEAD NatSpec (`:182-183`, `:240-242`) now declares the lag intentional: "A slash between reports is a loss that waits here on purpose". Under the third-party stance that is a trust gap, not a mitigation: the allocator (who controls every re-marking function) can hold shares and time an exit against an un-marked slash, and any never-admitted transferee can too.
```
[FAIL: exiting depositor must not be paid above the true share price: 499999999999999998500 > 414999999999999998841] test_H1_exitAtStaleMarkAfterSlash()
  underwriter true assets: 829999999999999999340   underwriter reported totalAssets (stale): 999999999999999999000
  alice fair share: 414999999999999998840   alice actually paid: 499999999999999998500
  bob value after report: 330000000000000000180   bob loss transferred from alice: 84999999999999998660
[FAIL: queued claim paid at stale mark: 499999999999999998500 > 414999999999999998841] test_H1_queuedExitAlsoAtStaleMark()
[FAIL: never-admitted transferee exits at the stale mark: 499999999999999998500 > 414999999999999998841] test_H1_noPermissionlessRemark_transfereeExitsAtStalePrice()
```
Numbers identical to rounds 1 and 2. Severity High, unchanged. (Entry-side pricing on the stale mark is P4, WS-C.)

### H-2 — Queue settlement order-dependent — FIXED for the drain (a843c1d); residual view over-credit, Low
**HEAD:** `contracts/ERC7540/ERC7540AsyncRedeem.sol:337-356` (`_claimableShares`: watermark `settledQueue + unlocked`, then `if (claimableShares > unlocked) claimableShares = unlocked` at `:355`), `:431-439` (`_claim`: `if (_shares > unlocked) revert` at `:434-435`), `:372-406` (`_claimFifo` decrements a live `remainingUnlocked`), `:226-242` (`maxRedeem` caps the per-controller sum at `unlocked`). The three round-1 tests now pass: a claim while `unlockedSupply() == 0` reverts and the market never moves from healthy to liquidatable.
```
[PASS] test_B1_juniorClaimSucceedsWhileUnlockedSupplyIsZero()   junior.unlockedSupply(): 0   junior.claimable(idA, alice): 0
[PASS] test_B1_juniorClaimDrainsLockedTranche()
[PASS] test_B1_seniorExitFlipsHealthyMarketToLiquidatable()   health before claim (ray): 1120000000000000000000000000   alice claim while locked: reverted   health after claim (ray): 1120000000000000000000000000   maxLiquidatable: 0
```
**Answer to the lead's question (gone or merely bounded):** bounded, not gone. `settledQueue` is still total-claimed, not a contiguous prefix (`:456`, NatSpec `:203-206` admits it), so a later request that settles first still shifts the watermark for every earlier open window. What the clamp changes is that *payouts* can never exceed live liquidity; what it does not change is that the per-request *views* over-credit and the sum across controllers exceeds `unlockedSupply()` (round-1 invariant I17 as a view invariant still fails), and that FIFO among already-claimable requests is not enforced at claim time — whoever transacts first takes the liquidity and the other's advertised amount reverts.
```
[FAIL: sum of advertised claimable must be deliverable: 300000000000000000000 > 261038961038961038960] test_H2_residual_sumClaimableExceedsUnlocked_butPayoutBounded()
  unlockedSupply: 261038961038961038960   claimable A (window 0): 200000000000000000000   claimable B (window 200): 100000000000000000000
  sum claimable <= unlocked (I17 view invariant): VIOLATED
  unlocked after A's claim: 61038961038961038960   bob claims his advertised amount: reverted (ExceededMaxRedeem)   bob claimable now: 61038961038961038960
```
Both post-claim assertions hold (`unlockedSupply == 0`, `healthiness ≥ 1e27`, `maxLiquidatable == 0`). Residual severity Low (integrator-facing: `claimableRedeemRequest`/`maxRedeem` are not deliverable quotes; a UI or the Underwriter's `finalizeDeallocateAsync` sized off them reverts). WS-B (P2/P3, I33) owns the queue going forward.

### M-1 — One dead feed bricks liquidation/write-off/redemption — OPEN (narrower), Medium
**HEAD:** `contracts/cap/Tranche.sol:216-219` (`getPrice` reverts `InvalidPrice` on 0), `:177-181` (`totalCapital` short-circuits only when `totalAssets() == 0`), `:163-174` (`unlockedSupply` short-circuits only when `lockedValue == 0`); aggregates `contracts/cap/market/BaseMarket.sol:292-297` (`totalCapital`), `:270-289` (`lockedValue`), `:230-234`, `:245-255`, `:258-267`, `:353-376`, `:380-386`. Exactly what still reverts with a funded 0.1% junior on a dead feed while the senior collateral crashed 70%:
```
[FAIL: InvalidPrice()] test_oneStaleFeedBricksLiquidationAndRedemption()
  market.healthiness: REVERT   market.maxLiquidatable: REVERT   market.unrecoverableDebt: REVERT   market.availableCredit: REVERT
  market.writeOff (GUARDIAN): REVERT   senior.totalCapital (own feed fine): ok   senior.unlockedSupply: REVERT
  senior.maxRedeem(alice): REVERT   senior.maxInstantRedeem(alice): REVERT   junior.unlockedSupply: REVERT   junior.totalCapital (dead feed): REVERT
  market.repay: ok   market.chargePremium (anyone): ok
```
The narrowing, characterised: `[PASS] test_narrowing_debtFreeTrancheExitsAfterFeedDies` (zero lock never consults the oracle) and `[PASS] test_narrowing_emptyDeadFeedTrancheDoesNotBrick`, which also shows that an *exited* junior is not empty — it keeps the 1000-wei dead-share seed, so `healthiness with 1000 wei of dead-feed junior: REVERT`. In practice the `assets == 0` bypass only helps a tranche that was never funded. Severity Medium, unchanged; under the third-party stance the market owner can `createTranche` with any priced asset (Registry.sol:177-199), so the choice of the fragile feed is now attacker-reachable (route to WS-D P11 / WS-E P14).

### M-2 — EMA defeated by a one-window par deposit — OPEN, Medium
**HEAD:** `contracts/cap/InterestRateModel.sol:227-239` (`averageUtilizationAfterMint` adds unabsorbed *credit* to both sides; a reserve-only deposit still enters the supply average through `_accrueAverage`, `:251-265`), `:156-164` (`fixedRatesAfterMint`), `contracts/cap/market/FixedMarket.sol:337-351` (`_borrowPremium`). The NatSpec claim "a flash deposit still cannot suppress the price" survives for the same-block case only.
```
[FAIL: a fully reversible deposit repriced a 30-day loan: 6778659191804096657793 != 8966376089664887623555] test_parkedDepositBuysADiscountOnTheWholeTerm()
  average utilization after 1 window parked: 0.490144523423634808997454286   honest 30-day liquidity premium (cUSD): 8966.376089664887623555
  manipulated premium (cUSD): 6778.659191804096657793   lenders lose (cUSD): 2187.716897860790965762   discount (bps of honest): 2439
  attacker capital cost at 10% APR (cUSD): 114.155251141552511415   profit multiple: 19
[FAIL: profitable across the whole band] test_bandDoesNotChangeTheOutcome()   period 300: 2440 bps, 230x   period 3600: 2439 bps, 19x   period 86400: 2439 bps, 0x
[FAIL: profitable even at the longest permitted window: 36208587602102130735568 != 54794520547945205479452] test_maxWindowStillProfitableForALargerLoan()   $5M/30d: 3391 bps, 6x
[PASS] test_flashDepositSameBlock_noDiscount()   honest 8966.376089664887623555 == same-block 8966.376089664887623555
```
Round-2 numbers reproduced to the wei. Severity Medium, unchanged (the borrower is a third party by stance; the park needs no role).

### M-3 — Premium attributed to whoever is present when it lands — OPEN, Medium
**HEAD:** `contracts/utils/PremiumVesting.sol:178-181` (`_fund` folds into `remainder`), `:232-246` (`_accrue` divides the vest over `staked` at accrual time), `:114-123` (`optIn` has no delay); `contracts/cap/market/FixedMarket.sol:235-242` (whole-term premium minted at borrow); `contracts/cap/Underwriter.sol:299-308` (`_report` sweeps and re-vests).
```
[FAIL: carol collected a share of a 30-day premium for 6 hours of exposure, then left: 1617069412303092062 != 0] test_JIT_fixedMarketUpfrontPremium()
  30-day term premium minted to tranche at borrow (cUSD): 8219178082191780821   carol take after 6h, bps of term premium: 1967   carol maxInstantRedeem after claim: 1000000000000000000000   carol redeemed collateral: 1000000000000000000000
[FAIL: a depositor absent during accrual should earn nothing from it: 2866236610937238823 != 0] test_JIT_floatingChargePremium()   carol take, bps of swept premium: 4323
[FAIL: a depositor absent during accrual should earn nothing from it: 3314841198817717850 != 0] test_JIT_underwriterReportWindow()   carol take, bps of swept premium: 5000
```
Identical to round 2 (19.7% / 43.2% / 50%). Severity Medium, unchanged.

### M-4 — Par exits before discretionary recognition — OPEN, Medium
**HEAD:** `contracts/cap/Stablecoin.sol:236-261` (`_convertToAssets` uses `badDebt` only), `:159-167` (`recognizeBadDebtInCredit`, MARKET-only, reached only via GUARDIAN `writeOff`, BaseMarket.sol:380-386), `:152-156` (`recognizeBadDebtInReserve`, GUARDIAN), `:170-181` (`coverBadDebt` retires only recognised debt). No permissionless or time-based recognition exists.
```
[FAIL: a redeemer exits at par ahead of the guardian and shifts the loss to survivors: 10000000000000000000000 > 8181818181818181818181] test_lagVsPrompt_halfTheReserveExitsAtPar()
  LAG:    A received 10000000000000000000000   flat backing after A 888888888888888888   B actually received 8000000000000000000000
  PROMPT: A received  8181818181818181818181   flat backing after A 909090909090909090   B actually received 8348794063079777365491
[FAIL: defaulting borrower exits the whole reserve at par: 19999000000000000000000 >= 19999000000000000000000] test_noPermissionlessRecognition()   (rando writeOff and recognizeBadDebtInReserve both revert)
[FAIL: A still exits at par before writeOff: 10000000000000000000000 >= 10000000000000000000000] test_coverBadDebtPublic_doesNotRecognise()
```
Severity Medium, unchanged.

### M-5 — Fixed loan-id reuse — FIXED (a843c1d)
**HEAD:** `contracts/cap/market/FixedMarket.sol:212-214` (`_requireLoan`: `id >= loanCount` → `LoanNotFound`), `:219-222` (`_requireOpenLoan`: `debt[id] == 0` → `LoanClosed`), applied at `:84` (`borrowMore`), `:93` (`extend`), `:119` (`extendAdmin`), `:128` (`repay`), `:143` (`liquidate`), `:152` (`writeOff`); `borrow` (`:64-75`) always mints `loanCount++`. Note: on HEAD `extend` is a **borrower** selector after `setBorrowerRole` (Registry.sol:222), not an owner one, so the round-1 "owner seeds, borrower draws" pair collapses to the borrower alone — and is refused.
```
[PASS] test_borrowerCannotSeedPhantomId()   [PASS] test_keeperCannotSeedPhantomId()   [PASS] test_unknownIdRefusedEverywhere()
[PASS] test_closedLoanCannotBeReopened()   [PASS] test_borrowNeverReusesIds()
[PASS] test_honestPathsAllChargeFullTerm()   honest 30d premium: 328767123287671232876712   borrow 1d + extend 29d premium: 339885960676382894435060
```

### R2-H1 — Curator drains the Underwriter via `addTranche` — OPEN, High
**HEAD:** `contracts/cap/Underwriter.sol:90-100` (`addTranche`: no provenance check, `IVault(vault).setOperator(_tranche, true)`, `IPremiumVesting(_tranche).optIn()`); the NatSpec at `:92-94` now *asserts* "curator is trusted to name a real protocol tranche". Selector in the curator's set at `contracts/cap/Registry.sol:499-504`; the curator role is minted by any WHITELISTED address via `createChildRoles` (`:116-134`, arbitrary parent). `Vault.setOperator` grants ERC-6909 operator over every id (Vault.sol inherits OZ ERC6909).
```
[FAIL: a curator must not be able to move depositor balances: 1000000000000000000000 != 0] test_curatorDrainsIdleBalanceViaAddTranche()   drained (tokens): 1000000000000000000000   alice shares now quote: 0
[FAIL: a WHITELISTED third party must not be able to custody depositor balances: 500000000000000000000 != 0] test_whitelistedThirdPartyBuildsItsOwnCurator()   third-party curator drained: 500000000000000000000
[PASS] test_stubbedFakeIsRemovableAfterDrain()   (loss unchanged by revocation)
[PASS] test_roleRevocationDoesNotClearVaultOperatorFlag()   (fake still drains after the curator is fired)
```
Severity High, unchanged; under the third-party stance the NatSpec trust declaration is the finding, not a mitigation. Fix unchanged from round 2: `IRegistry.isTranche` (add it) checked in `addTranche`. WS-C owns P1.

### R2-H2 — Invested reserve loss invisible — CHANGED (partially fixed e4a7b93/142ec65), severity Medium (lead may keep High)
**HEAD:** `contracts/cap/Stablecoin.sol:102-117` (`invest`/`recall`, KEEPER, still uncapped and unrecorded), `:120-124` (`setReserveVault`, GOVERNOR — new), `:152-156` (`recognizeBadDebtInReserve`, GUARDIAN — new, raises `badDebt` without touching `creditBackedSupply`), `:184-192` (`unlockedSupply` now `min(supply − locked, quote(on-hand))` — new), `:195-202` (`backing`/`totalAssets` still supply-derived), `:236-261` (curve keyed on `badDebt` only).
What is fixed: there is now a role-reachable path that books a reserve loss correctly, and the redemption views no longer advertise more than the contract holds (R2-L1). What is not: until GUARDIAN calls it, `totalAssets`, `backing` and `convertToAssets` do not see the loss and every redeemer exits at par; the loss lands entirely on whoever is last, exactly as in round 2. Confirmed as the lead asked:
```
[FAIL: a redeemer exits at par after an Aera loss; the whole loss lands on whoever is last: 500000000000000000000 > 450000000000000000001] test_lossInvisible_redeemerExitsAtPar()
  aera loss: 100000000000000000000   totalAssets while invested (unchanged): 1000000000000000000000   unlockedSupply while invested (on-hand cap): 500000000000000000000   backing(): 1000000000000000000000
  alice paid: 500000000000000000000   alice fair (pro-rata of real reserve): 450000000000000000000   bob maxInstantRedeem now: 400000000000000000000   bob convertToAssets(500): 500000000000000000000
[PASS] test_guardianRecognition_thenCurve()   alice on curve: 426315789473684210526   bob on curve: 447445143470922203468   (creditBackedSupply untouched; totalAssets 900e18)
```
Re-assessment: the structural half of the round-2 High ("no path to book it") is closed; what remains is the same recognition-lag class as M-4, applied to an off-chain-valued leg with no on-chain signal at all and an uncapped `invest`. I rate it Medium on the same basis as M-4; the lead's stated view that it is still OPEN is confirmed by the test, and if the lead weighs the missing on-chain signal and the uncapped invest more heavily, High is defensible. Recommendations from round 2 that still apply: cap `invest` at a fraction of `unlockedSupply − redemptionQueue`; record `invested` and expose `reserveVault` valuation in `backing()`; gate `setReserveVault` on `invested == 0` (§3 item 3).

### R2-M1 — Owner strips or reorders the waterfall — FIXED (e4a7b93); residual Low
**HEAD:** `contracts/cap/Registry.sol:435-437` (`setTranches` → REGISTRY), `:177-199` (`createTranche`: append only, weights array must be `existing + 1`), `contracts/cap/market/BaseMarket.sol:119-127` (`setTrancheWeights`: same length, same order), `:390-406` (`_setTranches`).
```
[PASS] test_ownerCannotStripOrReorder()   (owner setTranches → AccessManagedUnauthorized ×2; setTrancheWeights length-1 → InvalidMarket; order [t0, t1] intact; senior keeps its buffer)
[PASS] test_noProtocolRoleCanStripEither()   [PASS] test_createTrancheAppendsBelowExistingJunior()
```
Residual (route to lead, L-21 family): `_setTranches` accepts weight 0, so the owner can zero a funded, fully locked junior's premium while it stays first-loss:
```
[FAIL: a locked first-loss tranche must keep a nonzero premium weight: 0 <= 0] test_residual_ownerZeroesLockedJuniorWeight()   junior premium over 30d at weight 0: 0   senior premium over 30d: 13259364795270871395
```

### R2-M2 — Wrapper first-depositor capture / zero-share trap — FIXED (142ec65)
**HEAD:** `contracts/cap/Wrapper.sol:61-74` (`previewDeposit/previewMint` via `DeadShares.seedDeposit/seedMint`), `:81-85` (`_deposit` mints `DeadShares.SHARES` to `DeadShares.HOLDER` on the first deposit); `script/deploy/service/DeployInfra.sol:193-201` (`_seedWrapper`: `previewMint(1e18)` of underlying → cUSD → `Wrapper.deposit(cusd, DeadShares.HOLDER)`).
```
[PASS] test_oneWeiFirstDepositRefused()   (DepositBelowSeed(1, 1000))
[PASS] test_repro_victimKeepsShares_attackerTakesDust()   wrapper assets before victim: 981685209050967798684   victim shares: 408   victim fair shares: 407   attacker out (1001 wei in): 979918587979409786   victim redeemable: 399806783895599192811   (next depositor mints > 0)
[PASS] test_prefundedPremium_burnedToDeadShares()   value held by DeadShares.HOLDER (burned): 979725757535896006671   attacker out: 979725757535896006
```
Residual (Informational, §3 item 1): premium that vests while the seed dominates the Wrapper's supply accrues pro rata to `DeadShares.HOLDER` and is unrecoverable.

### L-1 — FIXED (a843c1d). `contracts/cap/market/FloatingMarket.sol:215-227` (`_premium` = three valuations using the same half-up product as `totalDebt`), `:148-167` (`_borrowWithin`/`_repayWithin`). `[PASS] test_dailyAccrualsOneYear_fullRepayAndWriteOffSucceed()   totalDebt 523762562549696708009 == creditBackedSupply 523762562549696708009   gap (wei): 0`; write-off path `unrecoverableDebt 429891556376199608693 ≤ credit 429891556376199608694`; `[PASS] testFuzz_debtNeverExceedsCredit (runs: 256)` with `assertEq(totalDebt, creditBackedSupply)` after every charge.

### L-3 — FIXED (2429b6c). `contracts/cap/market/BaseMarket.sol:315-322` (`variableCreditLimit = activeCapital · min(ltv, lt)`). `borrow` itself (`FloatingMarket.sol:60-72`) still has no post-borrow health assert, but the draw can no longer exceed the threshold: `[PASS] variableCreditLimit 4000e18 == debtLiquidationThreshold 4000e18   healthiness 1000000000000000000000000000   maxLiquidatable 0`.

### L-4 — FIXED (2429b6c). `contracts/cap/Registry.sol:106-107`. `[PASS] test_L4_registryRejectsLtEqualBuffer` (`InvalidLt`), `test_L4_registryRejectsLtAboveOne` (`InvalidLt`), `test_L4_registryRejectsLowTargetHealth` (`InvalidTargetHealth`), `test_L4_shippedDefaultsStillDeploy`.

### L-5 — OPEN, Low (P13/I38, WS-D). `contracts/cap/market/BaseMarket.sol:89-96` (`setLt` only `≤ 1e27` and `> buffer`).
```
[FAIL: health must lead recoverability: lt*(1+bonus) <= 1e27 is not enforced: 1001123595505617977528089888 >= 1000000000000000000000000000] test_L5_setLtPermitsHealthLaggingRecoverability()
  lt (ray): 990000000000000000000000000   healthiness (ray): 1001123595505617977528089888   recoverableDebt: 882352941176470588235   unrecoverableDebt: 7647058823529411765   written off on a healthy market: 7647058823529411765   (liquidate → Healthy())
[FAIL: setLt must reject lt*(1+bonus) > 1e27: 981392156862745098039215686 > 980392156862745098039215686] test_L5_boundNotEnforcedBySetter()
```

### L-6 — OPEN, Low. `contracts/cap/InterestRateModel.sol:105-115` (only `kink > 1e27` rejected; accrues before writing). `[FAIL: setLiquiditySlopes must be able to recover from a bad curve]   liquidityRate accepted (ray/yr): 1e37   setLiquiditySlopes(sane) after 30d: REVERTS`; `liquidityIndex`, `deposit`, `mintCreditBacked` all revert. GOVERNOR-only; upgrade-only recovery.

### L-8 / R2-L7 — FIXED (142ec65). `script/Deploy.s.sol` compiles under `forge build` (`foundry.toml:6` `script = "script"`), deploys through CreateX (`script/deploy/utils/CreateXUtils.sol:13,44-46`; no `getNonce(address(this))` / `computeCreateAddress` anywhere in `script/`), deploys the real `Oracle` + `ChainlinkAdapter` (`DeployInfra.sol:74-80`) and seeds the Wrapper (`:112`, `:193-201`). In-memory dry run: `STABLECOIN_UNDERLYING=0x…01 forge script script/Deploy.s.sol --sender 0x1000…01` → all ten implementations deploy (`new Underwriter@…`, `new Wrapper@…`), then `← [Revert] CreateX missing` at the first `_create3`: the only remaining precondition is the canonical CreateX at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` on the target chain and `previewMint(1e18)` of underlying in the broadcaster (documented at `Deploy.s.sol:15`). Role wiring of the produced deployment is WS-E's (I40).

### L-9 — FIXED (2429b6c). `contracts/cap/market/FloatingMarket.sol:195-202` (`_growIndex`: `(globalNow/lastGlobal)^multiplier` via `rayPowRay`), multiplier stored on the market (`BaseMarket.sol:144-152, 203-206`). `[PASS] premium at multiplier 1x: 221332933560973813056   2x: 491654134600654074185`; `[PASS] testFuzz_L9_floatingMultiplierMonotone (runs: 256)`; mid-way change and fixed contrast pass. Accuracy of `rayPowRay` is WS-A (P5, I28).

### L-10 — OPEN, Low (P9, WS-D). `contracts/cap/market/FixedMarket.sol:113-124` (`extendAdmin`), `:359-367` (`_chargePremiumForTerm` on full `debt[id]`); `FloatingMarket.sol:99-101` (public `chargePremium`). Correction from round 2 stands: `stablecoin.totalAssets` inflates 1:1 with the phantom debt.
```
[FAIL: write-off should not exceed the shortfall that existed before the rolls: 4815722449171194887455 != 4019607843137254901959] test_L10_keeperRollsMintUnbackedYieldOnDefaultedLoan()
  unrecoverable debt before rolls: 4019607843137254901959   debt growth (all phantom): 1650774693945761037669   stablecoin.totalAssets growth: 1650774693945761037669
  badDebt recognised at write-off: 5670382537083015939628   senior underwriter claimed cUSD: 1182382840084594765909   USDC redeemed from the reserve: 327722752172773713736
[FAIL: shortfall should not compound while nobody can recover it: 5630659394151735795194 != 4019607843137254901961] test_L10_floatingAccruesOnUnrecoverableDebtWithoutAnyRole()   cUSD minted meanwhile: 1611051551014480893233
```
(The final `assertEq` compares against `badDebt` after a partial `_onWithdraw` retirement, hence 4,815.7 vs 4,019.6; the write-off itself booked 5,670.4.)

### L-11 — FIXED (a843c1d). `contracts/cap/market/BaseMarket.sol:482-485` (`_earnsPremium`: `stakedSupply() > 0 && totalCapital() > 0`). `[PASS] junior totalAssets: 0   junior stakedSupply: 9999999999999999000   junior killed: yes   premium minted to wiped junior over 30 days: 0`; fixed-market rolls: `senior capital left 0 / junior 0 → premium 0 / 0`. Dust capital (> 0 wei) still takes the full weight — I39, WS-D.

### L-12 — OPEN, Low. `contracts/cap/Tranche.sol:71-95` (`slash`): the early returns at `:75` (`total == 0`) and `:84` (`slashedValue == 0`) do not cover a tranche holding only the 1000-wei dead-share seed (value 400 wei at $0.40 ≠ 0), so the latch at `:88` fires. `[FAIL] junior supply after exit (dead shares): 1000   junior assets after exit (wei): 1000   junior killed: true   junior maxDeposit: 0   re-deposit into junior: REVERT (ExceededMaxDeposit)`. Control `[PASS] test_L12_healthyJuniorSmallSlashNotKilled`.

### L-14 — OPEN, Low. `contracts/ERC7540/ERC7540AsyncRedeem.sol:87` (shares parked at `address(this)`), `contracts/utils/PremiumVesting.sol:116` (`address(this)` can never opt in), no cancel function (`CancelExceedsPending` declared at `IERC7540AsyncRedeem.sol:32`, unused). `[FAIL] stakedSupply after queue: 0   shares still queued and locked by debt: 714285714285714284715   30d underwriter premium routed to tranche: 0   routed to cUSD holders instead: 8287102997044294622   cancelRedeem: no such function   queued position 714285714285714284715 → 612285714285714284859 after slash`.

### L-15 / R2-L2 — OPEN, Low (now documented as deliberate). `contracts/cap/oracle/ChainlinkAdapter.sol:9-10` (NatSpec: clamps not inspected, "feed onboarding must verify"), `:20-32` (only `answer <= 0`); `Oracle.sol:72-77` (secondary only on 0/stale). `[FAIL] minAnswer (18 dec): 1.0   Oracle.price(asset) observed: 1.0   secondary (true) price: 0.0001`; adapter-level `[FAIL] adapter answer for a floor-clamped feed: 100000000000000000000`. Round-2 verifier's demotion (no live clamps on the 10 mainnet feeds checked) still applies; L2 feeds unverified.

### L-16 — OPEN, Low. `contracts/cap/oracle/Oracle.sol:95-101` (`_isStale` only when `now > lastUpdated`). `[FAIL] price served after 5 years of primary silence: 2000.0   primary stamp: 316360000   now: 158680000`; control passes.

### L-18 — FIXED (2429b6c). `contracts/cap/Vault.sol:34-37` (`safeTransferFrom` then `_mint`). `[PASS] 6909 balance seen mid-flight: 0   6909 supply seen mid-flight: 100000000000000000000   mid-flight withdraw: refused`.

### L-19 / L-20 / L-21 — OPEN, Low (model-owned; cheap checks). `InterestRateModel.sol:180-184`: `[FAIL] liquidationBonus after set(0): 0`. `BaseMarket.sol:245-255`: `[FAIL] healthiness 998400000000000000000000000   first clip, bps of debt: 5797   junior capital 31200000000000000000 → 0   junior killed: yes`. `BaseMarket.sol:130-134` → `InterestRateModel.sol:124-131` ("There is no lower bound"): `[FAIL] underwriter shares locked by the draw: 714285714285714285715` then `setUnderwriterRate(0)` succeeds. Under the third-party stance L-21 is an operator (market owner) harming another party's locked depositors with no floor and no notice; together with the R2-M1 weight-0 residual I suggest the lead consider Medium.

### R2-L1 — FIXED. `Stablecoin.sol:190-191` caps `unlockedSupply` by `quote(on-hand)`; `maxInstantRedeem`/`maxRedeem`/`claimableRedeemRequest` all derive from it. `[PASS] test_R2L1_viewsTrackOnHandBalance` (invest 600 of 1000 → unlocked 400; over-claim → `ExceededMaxRedeem`; recall → 500).

### R2-L3 — CHANGED, Low. `Oracle.sol:87` (`returnedData.length == 64`, 142ec65) closes the raw-feed-as-payload case: `[PASS] test_rawFeedAsPayloadIsRefused` (`PriceError`). `Oracle.sol:36` dry run still only `!= 0`: `[FAIL] setSource with the same feed twice: accepted   Oracle.price: 4000000.0` (= 2000²). GOVERNOR misconfiguration; Low.

### R2-L4 — OPEN, Low (code reading). `contracts/utils/PremiumVesting.sol:142-155`: `claim` calls `_settlePremium` (zeroes `pending`, resets `debt`, `:186-192`/`:266-276`) before clamping `premium` to `balanceOf(this)`; a binding clamp forfeits the excess, and on the Stablecoin `balanceOf(this)` also holds the redemption queue (`ERC7540AsyncRedeem.sol:87`), so a binding clamp would pay premium out of queued shares. Round-2 fuzz found 0 wei shortfall in 28k calls; the arithmetic floors in both directions (`:144-147`), so the clamp is defensive. Unchanged; no cheap test triggers it.

### R2-L5 — OPEN, Low (design). `PremiumVesting.sol:99, 200-218`. `[FAIL] premium pot: 6629682397635435697   bob (1 wei, opted in) claimable: 6629381445355228757   alice (1000e18, not opted) claimable: 0`. P18 (opt-in forfeiture) is WS-C.

### R2-L6 — FIXED (142ec65), residual Info. `Stablecoin.sol:120-124` (`setReserveVault`, GOVERNOR). `[PASS] test_R2L6_setReserveVault_noInvestedGate   recall from the new vault: REVERT (funds sit in the old vault)` — no `invested == 0` gate; switching back recovers. §3 item 3.

### C-1, L-2, L-7, L-17 — still FIXED on HEAD
C-1: `[PASS] ×4` — feed 2000e8 → `oracle.price` 2000e18 (`Oracle.sol:16`, `ChainlinkAdapter.sol:29-31`); `totalCapital` 2,000,000e18; credit 1,000,000e18; liquidation at $1,200 seizes `6815668202764976958000` USD vs owed `6815668202764976958525` (1e-15), partial. L-2: `[PASS] ×2` — `ReentrancyGuardReentrantCall`, burned 100e18, received 204e18, I3 exact (`BaseMarket.sol:21`, `FloatingMarket.sol:83-96`). L-7: `[PASS] ×2` — 52 restricted selectors on Registry-wired instances (the production wiring, `Registry.sol:351-511`) resolve to their named roles, `IRM.setAveragingPeriod → 2`, `Oracle.setSource → 2`; only `upgradeToAndCall` on the seven singletons and `upgradeTo` on the beacons resolve to ADMIN(0), by design (`Registry.sol:410-416`). L-17: `[PASS] ×2` — quiet `2132171.659109908382943133` vs 12-s accruals `…943135`, both 63% after one period; `testFuzz_emaPathIndependent (runs: 256)`.

## 3. Incidental observations (for the lead to route)

1. **Wrapper seed earns premium into the dead address** — `contracts/cap/Wrapper.sol:81-85` + `script/deploy/service/DeployInfra.sol:200` (`Wrapper.deposit(cusd, DeadShares.HOLDER)`). The 1e18 seed is *shares held by the dead address*, so every premium the Wrapper claims is split pro rata with it: 100% while the Wrapper has no other depositor, `1e18/(1e18 + TVL)` thereafter. `test_prefundedPremium_burnedToDeadShares` shows 979.7e18 of a 981.7e18 pot unrecoverable. A seed held by the protocol (or a dead balance excluded from `totalSupply` in the premium split) avoids the leak. Informational at scale; visible at launch.
2. **`setTrancheWeights` accepts weight 0 on a funded, locked tranche** — `BaseMarket.sol:390-406` only checks Σ = 1e27. Owner zeroes a junior's compensation while it remains first-loss and locked (`R2_M1_OwnerSetTranches.t.sol::test_residual_*`). Same family as L-21; under the third-party stance consider Medium together.
3. **`setReserveVault` has no `invested == 0` gate** — `Stablecoin.sol:120-124`; a switch with funds in the old vault makes `recall` revert until switched back (GOVERNOR-only, reversible). Also nothing records `invested`, so nothing can enforce such a gate today.
4. **`extend` is re-homed by `setBorrowerRole`** — `Registry.sol:429` puts `IFixedMarket.extend` in the owner's set at creation and `Registry.sol:222` moves it to the borrower's set when the owner calls `setBorrowerRole`. Plan §4 lists it under both; the effective holder after wiring is the borrower. Harmless (M-5 is closed either way), but the role table should say so.
5. **H-2 residual views** — `claimableRedeemRequest`/`maxRedeem` are not deliverable quotes across controllers after an out-of-order claim (§2 H-2). `Underwriter.finalizeDeallocateAsync` (Underwriter.sol:165-180) sizes its claim off the recorded request, not the view, so the Underwriter path is a revert-and-retry, not a loss. WS-B I33.
6. **M-1 attacker-reachability** — market owners are third parties and `createTranche` (Registry.sol:177-199) accepts any asset the oracle prices; the fragile-feed junior that bricks a market is now the owner's choice, and the dead-share seed keeps the brick alive after the junior is emptied. WS-D P11 / WS-E P14.

## Invariants
- I17 (round 1, `Σ_open claimableRedeemRequest ≤ unlockedSupply()`): still broken as a **view** invariant on Tranche after an out-of-order claim (`R1/H2_*::test_H2_residual_*`); holds for **payouts** (every claim re-checks live liquidity). Restate for WS-B as: `Σ actually claimed in a block ≤ unlockedSupply() at block start`.
- I3 (`Σ totalDebt == creditBackedSupply`): now holds **exactly** for a single floating market across 365 daily accruals and 256 fuzz sequences (L-1 fixed); the ±wei dust allowance in I30 can be tightened to 0 for floating premium.
- I38 (`lt·(1+bonus) ≤ 1e27 ⇔ unrecoverable > 0 ⇒ health < 1`): broken by construction at lt 0.99 (L-5).
- I16/I23 (no action against a stale Underwriter mark): broken (H-1).
- I25 (every Vault operator granted by an Underwriter is a Registry tranche): broken (R2-H1).
- I26 (`redeem(maxRedeem(a))` never reverts on the Stablecoin): holds after the on-hand cap (R2-L1) for the instant path; the async view/payout gap of I17 does not apply to the Stablecoin (its `unlockedSupply` only falls through claims).
- I27 (ordered tranche list invariant under `setTranches` while debt outstanding): holds (R2-M1 fixed); the Registry's `createTranche` is append-only.
- New invariant the code implies: `Wrapper` premium share attributed to `DeadShares.HOLDER` is unrecoverable — `Σ claimed by Wrapper − Σ redeemable by non-dead holders` grows monotonically (§3 item 1).

## Hypotheses
Workstream R owns no Pn. Results relevant to other owners: P1 (R2-H1) CONFIRMED on production wiring including the WHITELISTED-only path; P3 (H-2 regression) REFUTED for the drain, CONFIRMED as a view-level residual; P11 (M-1) CONFIRMED with the narrowing characterised; P12 (R2-H2 par exit after loss) CONFIRMED; P13/I38 (L-5) CONFIRMED at lt 0.99; P9 (L-10) CONFIRMED.
