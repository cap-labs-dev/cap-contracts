# Cap v2 round 3 — Workstream F: test-suite assessment and mutation testing

Target: branch `cap-network` @ `a843c1d`. Suite under `test/`: 47 files, 11,378 lines, 574 tests
(552 `test_`, 22 `testFuzz_`, **0** `invariant_`), 38 suites; baseline `forge test` 574/574 in 0.87 s wall.

Method: every file under `test/` was read in full; the 12 money-bearing contracts were read end to
end; then Gambit v1.0.6 mutants (sampled deterministically) and 29 hand-authored semantic mutants
were each run against the **full** suite in isolated git worktrees (see §2.1). Killing tests for
every dangerous survivor live in `audit/v3/tests/mutants/`. The measure of suite quality quoted
throughout is the **mutation score** (killed / (total − equivalent)); line coverage is not quoted
because `lcov.info` in the repo is April-2025 v1 data and because line coverage cannot distinguish
an executed line from an asserted one — this suite executes almost every line and, as §2 shows,
asserts a good deal less.

---

## 1. Qualitative audit of `test/`

### 1.1 Tests that assert nothing, or only that a call did not revert

Scanned mechanically (test bodies with no `assert*`/`expectRevert`/`expectEmit`/`expectCall`) and
then by hand. Genuine cases:

| Location | What it does | Why it is weak |
|---|---|---|
| `test/integration/Lender.t.sol:76-80` `test_setBuffer_and_setLt_success` | calls `setBuffer(0.2e27)`, `setLt(0.85e27)` | no assertion at all; does not even read the values back. A setter that silently ignored its argument would pass. |
| `test/integration/RoleTable.t.sol:208-218` `test_createMarket_acceptsRegisteredOperatorRoleIds` | creates a market with a role a co-owner holds, then `setLtv` as co-owner | only "did not revert"; the test contract holds ADMIN so the `createFloatingMarket` half proves nothing (see §1.7) |
| `test/integration/Tranche.t.sol:147-160` `test_depositorRoleMembershipDrivesAdmission` | admit → deposit → expel | the positive `deposit(1e18)` has no balance/share assertion; only the two rejections are checked |
| `test/integration/VestingSchedule.t.sol:52-65` `test_trancheStaysLiveWhilePremiumVests` | transfer, claim, deposit while vesting | `claim` and the second `_fundTranche` are asserted only by not reverting; `claim`'s return is dropped |
| `test/integration/AuditValidation.t.sol:17-29` `test_guardianLtReductionConstrainsFloatingBorrow` | `borrow(max)` after `setLt(0.2)` | the max-borrow half asserts only `healthiness ≥ 1e27`; the amount actually drawn is not checked |
| `test/unit/cap/InterestRateModel.t.sol:43-50` `test_averageSupplies_tracksTheSource` | `assertGt(credit, 0); assertGt(supply, 0)` | any non-zero pair passes; the mock's fixed `supply = 1e27` means `supply > 0` is unconditional |
| `test/unit/cap/Lender.t.sol:49-61` `test_utilizationAndPremiumIndicesAfterADraw` | `assertGt(utilization, 0)`, `assertGe(index, 1e27)` | the indices are exactly `1e27` at t=0, so `≥ 1e27` cannot fail; utilization only has to be non-zero |
| `test/integration/FixedExtend.t.sol:79-91` `test_borrowMore_onALiveLoan` | `assertGt(added, 0); assertGt(debt, debtBefore)` | never checks `added == 100e18` nor the premium charged |
| `test/integration/FixedExtend.t.sol:189-209` `test_liquidate_unhealthyFixedLoan` | `assertGt(repaid,0); assertGt(slashed,0); assertEq(debt, before − repaid)` | the only fixed-market liquidation test; repays `max` so `debt % repaid == debt − repaid` — Gambit mutant `FixedMarket#129` (`debt[id] -= repaid` → `%=`) **survives** (§2.3) |
| `test/integration/RewardRouting.t.sol:84-103` `test_liquidation_slashesTranche1ThenTranche0` | `assertLe(after, before)` on both tranches | "did not increase" — a liquidation that slashed nothing, or the wrong tranche first, passes |
| `test/integration/LendingFlow.t.sol:150-166` `test_liquidate_unhealthyMarket_repaysAndSlashes` | `assertGt(repaid,0)`, `assertGe(collateral, before)`, `assertLe(slashed, deposits)` | the bonus, the ordering and the amount are all unasserted |
| `test/integration/DebtLifecycle.t.sol:82-103` `test_extendAdmin_rollsOverdueLoanAndGrowsDebt` | `assertGt(debt, debtBefore)` | the arrears premium is never quantified; a 1-wei charge passes |
| `test/unit/cap/Underwriter.t.sol:343-350` `test_totalAssets_isVaultBalancePlusDebt` | asserts `500e18` with `totalDebt == 0` | the "+ debt" half of the formula is untested |

`git log --all -S 'vm.skip' -- test/` finds `1d5b80c` "Disable failing tests" (2025-04-04) and
`54618f5` "dont skip any tests" (2025-04-06) — both pre-date v2 and no `vm.skip` remains.

### 1.2 Assertions that restate the implementation

These compute the expected value with the same formula (or the same contract view) as the code
under test, so a wrong formula passes:

| Location | Restated formula |
|---|---|
| `test/unit/utils/PremiumVesting.t.sol:100-104` `_vested()` used at `:132,136,213` | reimplements `PremiumVesting._weight/_vested` (`RAY − retention.rayPow(elapsed)`, floor mulDiv) verbatim; `assertEq(v.vested(), _vested(...))` cannot catch a wrong time constant or rounding direction. Only `:137` pins an external number (`632/1000`, 1 % tolerance). |
| `test/unit/utils/PremiumVesting.t.sol:154-162` | `assertEq(v.perShare(), due.rayDiv(1_000e18))` where `due = v.vested()` — expected from the contract's own view |
| `test/unit/cap/InterestRateModel.t.sol:242-247, 268-273` | `averageUtilizationAfterMint(x)` compared to `(credit + extra + x) * 1e27 / (supply + extra + x)` where `credit/supply/extra` are all read from the IRM — literally the body of `averageUtilizationAfterMint` |
| `test/integration/DebtLifecycle.t.sol:186-192` | `shortfall = unrecoverableDebt()`; `assertEq(shortfall, totalDebt − recoverableDebt())` restates the definition; `assertEq(written, shortfall)` compares `writeOff()` to the view it is implemented from. Only `:184` (`≈98.04e18`) is independent. |
| `test/integration/AccountingIntegrity.t.sol:418-438, 441-466` | `debtAfter − debtBefore == liquidityPremium + underwriterPremium` and `creditMinted == premium()` — all four operands are contract views. A `_premium` that mis-split or over-accrued **consistently** (e.g. hand mutant H06 swapping the split, or a wrong `_growIndex`) passes; only the *internal* consistency is pinned. |
| `test/integration/Tranche.t.sol:725-739`, `PremiumBacking.t.sol:113-129`, `RewardRouting.t.sol:52-66` | `juniorShare = underwriterPremium * weight / 1e27` with `underwriterPremium` from `market.premium()` — the split is checked against the contract's own quote, never against rate × time × principal |
| `test/integration/MarketMultiplier.t.sol:78-91` | view vs realised — consistency only |
| `test/unit/cap/Stablecoin.t.sol:437-445` | `quoteWithdraw(convertToAssets(50e18)) == 50e18` — a round trip, which holds for any monotone pair of inverse curves, right or wrong |
| `test/integration/AccountingIntegrity.t.sol:1355-1362` `_premiumAt` | reimplements the kink curve and term multiplier; used once (`:1254`) — this one is the *good* kind (differential against an independent re-derivation) |

The strongest independent pins in the suite are the hard-coded numbers in `Stablecoin.t.sol`
(`37.3134…`, `17.2413…`, `911.6279…`, `801.0989…`), `LockedValue.t.sol:41,80` (`714285714285714285714`),
`PricedCollateral.t.sol` (`51e18`, `204e18`, `469e18`) and `RateConvention.t.sol:34` (`1_221.4e18`).
Those files are what actually kills mutants in the money paths (§2.3).

### 1.3 Over-mocked tests and the 18-decimal underlying

| Mock | Assumption it bakes in | Tests relying on it | What the mock hides |
|---|---|---|---|
| `MockIRM` (`test/shared/mocks/MockIRM.sol`) — `liquidityIndex()==underwriterIndex()==1e27` forever, `liquidationBonus()==0.02e27`, `updateLiquidityRate` is a counter | indices never move; bonus constant | all of `Stablecoin.t.sol`, `Wrapper.t.sol`, the `scoin` instance in `AccountingIntegrity.t.sol:34-58` | every Stablecoin/Wrapper unit test is blind to the rate feedback loop (`_deposit`/`_burn` → `updateLiquidityRate` → utilization → rate). `irm.updateCalls()` assertions (`Stablecoin.t.sol:86,220,548`) test that the hook *was called*, not what it did. |
| `MockAeraVault` — pulls on deposit, pushes on withdraw, never loses, never refuses | reserve vault is lossless and always liquid | `Stablecoin.t.sol:921-980` (invest/recall/redeemAfterInvest) | `recall(amount)` failing or short-paying (Aera has withdrawal constraints), `invest` of more than on-hand (the real vault would revert; the mock also reverts but only on `safeTransferFrom` — fine), a loss in Aera that GUARDIAN must recognise via `recognizeBadDebtInReserve` — the loss path is only tested with the loss injected by hand (`:204-221`) |
| `MockAggregator` — 8-dec feeds, `FEED_STALENESS = 3650 days` (`CapDeployer.sol:46`) | prices never go stale during 10-year warps | every `CapDeployer` integration test warps up to `3650 days` (`LendingFlow.t.sol:455`, `AccountingIntegrity.t.sol:376`) on a single posting | every liquidation / interest-accrual scenario runs on a price that a real 1-hour window would have rejected; the only staleness tests are `Tranche.t.sol:224-239` and `Oracle.t.sol`. Nothing exercises "feed goes stale **while debt is outstanding** and a liquidation must still happen" (plan P11). |
| `MockUtilizationSource` — `supplies()` returns `(u, 1e27)` | supply is constant; credit is the knob | all of `InterestRateModel.t.sol` | the real stablecoin moves *both* supplies (deposit raises supply only, borrow raises both, redeem lowers supply). `unsmoothedCredit`/`averageUtilizationAfterMint` are therefore never tested with a supply-side move, which is the flash-deposit vector the averaging exists for (that vector is tested end-to-end only in `AccountingIntegrity.t.sol:1186-1223`). |
| `MockCreateX` | CREATE3 address formula | `Deployment.t.sol` | only the deploy script's own salt shape; harmless |
| `vm.mockCall` on `tranche`/`vault` in `test/unit/cap/Underwriter.t.sol:58-64,283-286` | `convertToAssets` returns 0 or a fixed number | whole file | `_mark` gain/loss arithmetic is exercised only with mocked constant valuations; the loss branch is exercised only in integration (`AccountingIntegrity.t.sol:942-1055`) |

**18-decimal underlying.** `CapDeployer.sol:172` deploys `MockERC20("USD Coin","USDC",18)`;
mainnet cUSD's underlying is 6-decimal USDC. Only `Stablecoin.t.sol:238-287` (`_stablecoinOn(6)`,
three tests: `previewMint` rounds up, `previewDeposit` exact, `totalAssets` in underlying units)
and `LockedValue.t.sol:86-115` (6-dec *collateral*, not underlying) run at 6 decimals. At
`underlyingDecimals = 6` every assertion below is on a path whose arithmetic changes
(`Stablecoin._convertToAssets/_convertToShares` scale by `1e12` before/after the shortfall curve,
`_onWithdraw` computes `paidInShares = assets * 1e12`, `unlockedSupply` caps at
`_quoteWithdraw(balance)`, `totalAssets = backing / 1e12` floors):

- `AccountingIntegrity.t.sol:87,91-95,118-122` (`badDebt == before − (100e18 − paid)` exactly; `convertToAssets(totalSupply) == usdc.balanceOf` exactly) — at 6 dec `paid` is a 6-dec figure and the haircut is `100e18 − paid·1e12`; the "no reserve stranded" equality holds only up to `1e12` share-wei.
- `Stablecoin.t.sol:392-394, 544, 563, 658-660` (`assetsBefore − totalAssets == paid`, `badDebt == 60e18 − (40e18 − assets)`) — same 1e12 quantisation; `assertEq` becomes `assertApproxEqAbs(…, 1e12)` at best.
- `Stablecoin.t.sol:512-530` `test_fifoWithdraw_paysOneAtomAcrossDustReceipts`: at 18 dec the atom costs a handful of shares and the loop `for (i < shares) requestRedeem(1)` runs a few times; at 6 dec `quoteWithdraw(1)` is ≥ `1e12` shares and the loop is unrunnable — the test as written **cannot be ported**, and the behaviour it pins (dust receipts pay the atom) is untested at mainnet decimals.
- `Stablecoin.t.sol:438-445` inverse round trip: at 6 dec `quoteWithdraw(convertToAssets(s))` can differ from `s` by up to `1e12` shares.
- `AccountingIntegrity.t.sol:101-123` (async vs instant identical) — holds at 6 dec only if both paths quantise identically; not tested.
- `Wrapper.t.sol` entirely (stcUSD is the live product); `test_withdrawClaimsVestedPremiumBeforePricingTheShare:142` uses `assertApproxEqAbs(…,1)`.
- Every `_mintStable(liquidator, x)` + `liquidate` test is unaffected (cUSD is 18-dec regardless), but the borrower-side `repay` after `deposit` (`PremiumBacking.t.sol:62-68`) deposits `short` underlying at 18 dec; at 6 dec `previewDeposit` floors and the borrower is short by up to `1e12−1` wei of cUSD and the full repay fails — a **liveness** difference the suite would only see at 6 dec.

`audit/v3/tests/shared/CapDeployer6.sol` (Workstream A) exists for exactly this; the killing tests
in §3 that touch the stablecoin curve are run at both widths.

### 1.4 Function-by-function coverage of the in-scope contracts

Legend: **a** valid-input test, **b** invalid/boundary-input test, **c** unauthorized-caller test
(an actual call from an address lacking the role, expecting revert — not a `RoleTable` wiring
assertion), **d** dirty-state test (after a slash / with bad debt / with queued requests / on an
expired loan). `–` = none found; `~` = partial (see note). Views are listed only where a wrong
value is money-bearing.

**BaseMarket** (`contracts/cap/market/BaseMarket.sol`)

| function | a | b | c | d | notes |
|---|---|---|---|---|---|
| setDepositorRole | ✓ RoleTable:399-408 | – | – | – | no PublicRole / non-operator guard test (P15) |
| setBorrowerRole | ✓ | – | – | – | never tested with another owner's operator role (P15) |
| setLtv | ✓ | ✓ Lender:70 | ✓ Lender:61, RoleTable:239 | – | |
| setBuffer | ✓ | ✓ LockedValue:152 | – | ✓ AccountingIntegrity:1458 (with debt) | no non-guardian caller test |
| setLt | ✓ | ~ LockedValue:165 (`≤ buffer` only; `> 1e27` bound untested — hand mutant H24 **survives**) | – | – | dropping lt below ltv with debt outstanding never followed by a liquidation |
| setFixedCreditLimit | ✓ | – | ✓ Lender:24 | – | |
| setTargetHealth | ✓ | ✓ LockedValue:180 | ✓ Lender:37 | – | |
| setTranches | – (only via Registry) | – | ✓ Tranche:385, DebtLifecycle:301 | – | the unhealthy-revert branch only via `createTranche` |
| setTrancheWeights | ✓ | ✓ | ✓ | – | never after a slash / with debt |
| setUnderwriterRate | ✓ | ✓ IRM:140 (via IRM) | – | ✓ MarketMultiplier:116 (after borrow) | no owner-role negative test; index checkpoint on rate change untested (H23 **survives**) |
| setMarketMultiplier | ✓ | ✓ | – | ✓ DebtLifecycle:52 | |
| healthiness / maxLiquidatable / recoverableDebt / unrecoverableDebt / lockedValue | ✓ | ✓ | n/a | ✓ (after price crash) | `lockedValue` partial-junior-cover branch **untested** (Gambit `BaseMarket#161` survives); `maxLiquidatable` never pinned to a number, only "lands on target" |
| variableCreditLimit / creditLimit / availableCredit | ✓ | – | n/a | ~ AuditValidation:22 (`lt < ltv`) | |

**FloatingMarket**

| function | a | b | c | d |
|---|---|---|---|---|
| borrow | ✓ | ✓ (0, > credit) | ✓ LendingFlow:59 | ~ never immediately after a warp without an explicit `chargePremium()` — Gambit `FloatingMarket#17` (drop accrual in `borrow`) **survives** |
| repay | ✓ | ✓ (0, sub-unit) | n/a (public) | ✓ after 730 d |
| liquidate | ✓ | ✓ Healthy() | **–** (no non-LIQUIDATOR call) | ✓ after crash / with bad debt |
| chargePremium | ✓ | n/a | n/a | ✓ |
| writeOff | ✓ | ✓ InvalidAmount | **–** | **–** never after time has elapsed since the last charge — Gambit `FloatingMarket#29` (drop accrual in `writeOff`) **survives** |
| setMarketMultiplier | ✓ | ✓ | – | ✓ |

**FixedMarket**

| function | a | b | c | d |
|---|---|---|---|---|
| borrow | ✓ | ✓ InvalidTerm (via limits), zero max term | **–** | – |
| borrowMore | ~ (amount unasserted) | ✓ expired, below min term, closed, out of range | **–** | – |
| extend | ✓ | ✓ | **–** | ✓ expired path; **never** with health near 1 (H19 drop-Unhealthy **survives**) |
| extendAdmin | ✓ | ✓ grace, > max | **–** | ✓ 365 d overdue |
| repay | ✓ | ✓ id range | n/a | ✓ overdue |
| liquidate | ~ FixedExtend:189 only | – | **–** | ✓ price crash; only `max` repaid (`FixedMarket#129` survives) |
| writeOff | ✓ | – | **–** | ✓ shortfall > half the loan only (`FixedMarket#161` survives) |
| setTermLimits | ✓ | ✓ | **–** | ✓ lowered under a live loan |
| availableCredit(term) | ✓ | ✓ term > max | n/a | ~ same-window catch-up branch untested (H25 **survives**) |
| premiumForBorrow/Extension | ✓ | – | n/a | ✓ |

**Tranche**

| function | a | b | c | d |
|---|---|---|---|---|
| deposit / mint | ✓ | ✓ below seed, killed | ✓ Tranche:190 | ✓ after donation, after kill |
| slash | ✓ | ✓ empty, sub-token | ✓ stranger + foreign market | ✓ |
| fund | ✓ | – | ✓ griefer | ✓ idle |
| setDepositorRole | ✓ RoleTable:354 | – | **–** | – |
| unlockedSupply / totalCapital / activeCapital | ✓ | ✓ dead feed | n/a | ✓ | Ceil→Floor on `lockedAssets` (H11) needs a price that does not divide exactly |
| requestRedeem / redeem / withdraw / instantRedeem (inherited) | ✓ | ✓ | ✓ (allowance ≠ claim) | ✓ queued while borrowed |

**Underwriter**

| function | a | b | c | d |
|---|---|---|---|---|
| addTranche | ✓ (mock + real) | **–** (arbitrary address accepted; P1) | ✓ RoleTable:519, Underwriter-int:95 | – |
| removeTranche | ✓ | – | **–** | ✓ with debt (reports first); **not** with a queued request outstanding |
| allocate | ✓ | ✓ unregistered | ✓ | – |
| deallocate | ✓ | ✓ oversize → short fill | **–** | ✓ after slash |
| deallocateAsync / finalizeDeallocateAsync | ✓ | ✓ unknown id | **–** | ✓ slash mid-queue |
| setDefaultTranche | ✓ | ✓ | ✓ | – |
| report | ✓ | ✓ unregistered | **–** | ✓ |
| setDepositorRole / setAllocatorRole | ✓ | – | **–** | – |
| deposit / mint | ✓ | ✓ seed | ✓ | ✓ default-tranche removed |
| totalAssets / unlockedSupply | ✓ | – | n/a | ✓ stale mark **enshrined** (`AuditSecurity.t.sol:58-82`) |

**Stablecoin**

| function | a | b | c | d |
|---|---|---|---|---|
| deposit / mint / fund | ✓ | ✓ (19-dec refused) | n/a | ✓ with bad debt (deposit at par) |
| mintCreditBacked / burnCreditBacked / fundCreditBacked | ✓ | – | ✓ mint, fund; **–** burn | ✓ |
| recognizeBadDebtInCredit / Reserve | ✓ | ✓ reserve > supply; **–** credit > supply (H21 **survives**) | ✓ | ✓ |
| coverBadDebt | ✓ | ✓ none, over | n/a | ✓ |
| invest / recall / setReserveVault | ✓ | – | ✓ | ✓ redeem needs recall |
| requestRedeem / redeem / withdraw / instantRedeem | ✓ | ✓ | ✓ | ✓ bad debt, invested reserve |
| unlockedSupply | ✓ | – | n/a | ✓ credit + bad debt; **on-hand cap only through `invest`** (`Stablecoin.t.sol:963-980`, and only via an expectRevert with no selector) |
| _convertToAssets/_convertToShares | ✓ (18 dec) | ~ (6 dec: previews only) | n/a | ✓ |

**InterestRateModel** — setters have (a),(b),(c) except `setTermMultiplierSlope` (no c) and
`updateUnderwriterRate` (c only in the sense that the caller is pranked as the market; no
non-market caller test). `fixedRatesAfterMint` is never called directly (0 hits). The index
checkpoint in `updateUnderwriterRate` has no test that lets time elapse first (H23 survives).

**Registry** — `createChildRoles`/`create*` have (a),(b),(c). `createTranche` has (a),(b),(c),(d
unhealthy). `setDepositorRole` has (c) via stranger only; **no** test that a market owner can point
tranche deposits at `PUBLIC_ROLE` or at a protocol role (P15). `setBorrowerRole`: no test that a
role registered by *another* WHITELISTED user is accepted (P15). `marketOwnerRole`: ✓.

**Oracle** — thorough: (a),(b) (short/long return data, revert, no code, stale, future-stamped,
truncation), (c) `setSource`. **ERC7540AsyncRedeem** — thorough on the mock vault; the FIFO/clamp
logic has (a),(b),(c); no gas/scale test for `n` requests (P2). **PremiumVesting** — thorough on
the harness; the `_update` skip-accrue branch is pinned by a gas assertion
(`Stablecoin.t.sol:110-137`), which is fragile but real. **Vault** — (a),(b),(c); no
fee-on-transfer / rebasing token test (P20). **Wrapper** — (a) only; no redeem-under-haircut test.

### 1.5 Multi-actor / multi-block sequences (plan P1–P22)

| Pn | Any test resembling it? | Closest test |
|---|---|---|
| P1 curator `addTranche(arbitrary)` drain | **No.** `Underwriter.t.sol:375` registers a `makeAddr` tranche and only checks `optIn` was called — it demonstrates the door is open, and asserts nothing about what is behind it. | |
| P2 dust-request flood / OOG | **No** gas or scale test; max requests in any test is 4 (`ERC7540AsyncRedeem.t.sol:455-483`) | |
| P3 out-of-order settlement over-credit | **Yes** — `ERC7540AsyncRedeem.t.sol:152-231` (unit), `AccountingIntegrity.t.sol:872-907` (integration) | |
| P4 stale Underwriter mark | **Enshrined, not tested against**: `AuditSecurity.t.sol:58-82` asserts the exiting depositor is overpaid by `> 249e18` and calls it "the intended share-price model". Entry-side (`deposit` pricing on a stale mark) has no test. | |
| P5 `rayPowRay` accuracy / monotonicity / `≥ RAY` | **No.** `WadRayMath.t.sol:189-234` pins seven point values at `1e12` relative tolerance; no fuzz, no lower bound, no bound on `exp <<= k`. | |
| P6 same-block floating + fixed pricing | **No** floating/fixed mix; `AccountingIntegrity.t.sol:1283-1341` is fixed-only | |
| P7 expiry / one defaulter blocks `extend` | **No.** `DebtLifecycle.t.sol:82-163`, `FixedExtend.t.sol` cover one loan at a time. | |
| P8 borrower opt-in captures `fundCreditBacked` | **No** | |
| P9 permissionless `chargePremium` on an insolvent market | **No**; every insolvent-market test writes off in the same block as the crash | |
| P10 waterfall dust | **Partial** — `PricedCollateral.t.sol:208-260` covers junior floor-to-zero carried to the senior; not the case where the *senior* also floors (`slashed < repaid·(1+b)`), nor liquidator profitability | |
| P11 dead feed with debt outstanding | **Enshrined**: `Tranche.t.sol:292-308` asserts `unlockedSupply`/`totalCapital` **revert** and stops there; nothing checks that liquidation/write-off are then also impossible (M-1) | |
| P12 front-run `writeOff` with par `instantRedeem` | **No** | |
| P13 `lt ≥ 1/(1+b)`: write-off possible while `liquidate` reverts `Healthy()` | **No** | |
| P14 WHITELISTED composition (own market, own tranche, own borrower) | **No**; `RoleTable.t.sol:220-245` shows a creator and owner can be different addresses and stops | |
| P15 `createChildRoles(GOVERNOR, …)`, PublicRole depositor, foreign borrower role | **Enshrined**: `RoleTable.t.sol:108-123` and `CapDeployer._assignOperator` create every operator role as a child of **GOVERNOR** | |
| P16 upgrade authority | (c) exists for every UUPS contract with a stranger; positive path only as ADMIN | |
| P17 `removeTranche` strands post-removal premium | **No**; `Underwriter.t.sol:391-405` reports *before* removing | |
| P18 senior `stakedSupply==0` redirects premium to cUSD | **Enshrined** as intended: `Tranche.t.sol:709-740`, `PremiumBacking.t.sol:97-130`, `RewardRouting.t.sol:45-69` | |
| P19 hook-token reentrancy | **Yes** for market guard + kill latch (`LiquidationReentrancy.t.sol`); not for cross-tranche/cross-market read-only reentrancy mid-waterfall | |
| P20 `Vault.deposit` mints `_amount` not received | **No** fee-on-transfer test; ordering test only (`Vault.t.sol:61-82`) | |
| P21 dead selectors on markets | **No** | |
| P22 live-proxy upgrade | **No**; `Deployment.t.sol` deploys fresh proxies | |

### 1.6 Invariants I1–I40 with no test

There are **0** `invariant_` functions under `test/`, so no invariant is checked statefully. The
column says whether an equivalent *unit* assertion exists anywhere.

| Inv | Unit-level equivalent in `test/`? |
|---|---|
| I1 reserve ≥ unlockedSupply | ~ `Stablecoin.t.sol:768-782` (one state), `:963-980` (invested) |
| I2 supply ≥ credit + badDebt | – (H21 survives) |
| I3 Σ debt == creditBackedSupply | ✓ single market, `AccountingIntegrity.t.sol:913-928`, `DebtLifecycle:39-59`; never across two markets, never after a write-off with elapsed time (FloatingMarket#29 survives) |
| I4 badDebt only falls via cover/_onWithdraw | – |
| I5 healthy ∨ unrecoverable ∨ liquidatable-and-profitable | – (profitability never asserted) |
| I6 Σ weights == 1e27 | ✓ setters reject |
| I7 lockedValue monotone in seniority | – (partial-cover branch untested) |
| I8 variableCreditLimit ≤ threshold | ~ `AuditValidation:17-29` |
| I9 tranche share price only falls via slash | – |
| I10 split-equivalence of the shortfall curve | ✓ `Stablecoin.t.sol:406-429, 583-610` |
| I11 round trip never profits | ~ `:642-661` (`paid ≤ shares`) |
| I12 vault token balance ≥ ERC-6909 supply | – |
| I13 queue conservation | – (only `activeSupply`/`redemptionQueue` spot checks) |
| I14 premium conservation | ✓ single-charge, `PremiumBacking.t.sol` |
| I15 FIFO | ✓ `ERC7540AsyncRedeem.t.sol:138-148` |
| I16 accrual before action | **–** and the two surviving `_chargePremium()` deletions show it |
| I17 Σ claimable ≤ unlockedSupply | ✓ `:204-231` (unit) |
| I18 stakedSupply == Σ opted balances | ~ many spot checks |
| I19/I20 premium conservation, remaining ≥ 0 | ~ spot checks |
| I21 wrapper price non-decreasing | – |
| I22 EMA path independence | ✓ `InterestRateModel.t.sol:328-356` |
| I23 underwriter mark == live valuation | ✓ `AccountingIntegrity:977-992` (fuzz, after `deallocate` only) |
| I24/I40 role table | ✓ `RoleTable.t.sol` (wiring only) |
| I25 operators granted by Underwriter are Registry tranches | – |
| I26 `redeem(maxRedeem(a))` never reverts | ~ `ERC7540AsyncRedeem.t.sol:204-231` one case |
| I27 `setTranches` under debt | ✓ unhealthy revert |
| I28 `rayPowRay ≥ RAY`, monotone, overflow bound | – |
| I29 `_growIndex` split error directional | ~ `MarketMultiplier:63-76` (1e12 rel tolerance, no direction) |
| I30 Σ_m debt == credit after charge (master) | single-market only |
| I31 `_borrowWithin`/`_repayWithin` shortfall ≤ idx/RAY + 1 | ~ `AccountingIntegrity:209-362` (`≤ request`, not the bound) |
| I32 `principal ≤ availableCredit(term)` ⇒ borrow succeeds, healthy | ✓ `:1143-1156` (max only) |
| I33 request-set conservation | – |
| I34 cUSD on hand ≥ queue + remaining | – |
| I35 credit + badDebt ≤ supply | – |
| I36 6-dec inverses | – (previews only) |
| I37 `Underwriter.totalAssets ≥ live` | – (the opposite is asserted in `AuditSecurity`) |
| I38 `lt·(1+b) ≤ 1` ⇔ write-off ⇒ liquidatable | – |
| I39 dust-capital killed tranche keeps premium weight | – |

### 1.7 The harness grants the test contract every role

`test/shared/CapDeployer.sol:263-273` grants `address(this)` GOVERNOR, KEEPER, GUARDIAN, ADMIN,
PROTOCOL, WHITELISTED and MARKET, and `_assignOperator` makes it (or any market owner/borrower it
names) an operator with **GOVERNOR** as role admin. `_deployUnderwriter` makes `address(this)`
curator *and* allocator. Consequences:

- Every positive "role X can do Y" assertion where the caller is `address(this)` is vacuous: with ADMIN (role 0) held, a selector that fell through to role 0 by omission is callable too. `RoleTable.t.sol` is the *only* thing distinguishing "wired to GUARDIAN" from "unwired", and it is a snapshot (its own NatSpec says so).
- The "only authority" tests that are **not** vacuous are those pranking a fresh address: `test/integration/Lender.t.sol:24,37,61`, `test/unit/cap/Lender.t.sol:19`, `Rewarder.t.sol:24`, `LendingFlow.t.sol:59`, `Stablecoin.t.sol:75,163,198,843,900,949,955,790`, `InterestRateModel.t.sol:59,72,372,386`, `Underwriter.t.sol:129,309,326`, `Underwriter-int:84,95`, `Tranche.t.sol:190-215,385`, `RoleTable.t.sol:174-206,239,510,523`, `Oracle.t.sol:362,377`, `Deployment.t.sol:93,208`, `Vault.t.sol:65,127,146`, `Registry.t.sol:117,139`, `Wrapper.t.sol:169`, `DebtLifecycle.t.sol:301`.
- Selectors with **no** unauthorized-caller call anywhere: `setBuffer`, `setLt`, `setMarketMultiplier`, `setUnderwriterRate`, `setDepositorRole`, `setBorrowerRole` (markets); `FloatingMarket.liquidate`, `FloatingMarket.writeOff`; every `restricted` `FixedMarket` function (`borrow`, `borrowMore`, `extend`, `extendAdmin`, `liquidate`, `writeOff`, `setTermLimits`); `Stablecoin.burnCreditBacked`; `InterestRateModel.setTermMultiplierSlope`, `updateUnderwriterRate` (non-market caller); `Underwriter.deallocate`, `deallocateAsync`, `finalizeDeallocateAsync`, `report`, `removeTranche`, `setDepositorRole`, `setAllocatorRole`, `mint`; `Tranche.setDepositorRole`, `mint`; `BeaconFactory.create`. `RoleTable` asserts the wiring for all of these but never exercises the gate.
- Because `address(this)` is simultaneously market owner, curator, allocator, guardian, governor, keeper and MARKET, no test can observe a *cross-role* boundary: e.g. a curator calling a guardian function, a market owner writing off, a keeper slashing. Every "third party" in the trust model (§4 of the plan) is the same EOA in the tests.

### 1.8 Loosened or re-pinned assertions since `3dad5ef`

`git diff 3dad5ef..HEAD -- test/ | grep -E '^[-+].*assert'` is 438 lines; the ones that widen or flip:

| Commit | Location | Change | Likely reason |
|---|---|---|---|
| `2429b6c` | `AuditValidation.t.sol:28` | `assertLt(healthiness, 1e27)` → `assertGe(healthiness, 1e27)` after `setLt(0.2)` + `borrow(max)` | `variableCreditLimit` now uses `min(ltv, lt)` so a max borrow lands exactly on the threshold; expectation flipped to match the new behaviour (legitimate, but note it is the *only* assertion on the value drawn). |
| `2429b6c` | `AccountingIntegrity.t.sol` (then `test_debtNeverExceedsCreditBackedSupply`) | `assertLe(totalDebt, creditBackedSupply)` | in `a843c1d` tightened back to `assertEq` — a **tightening**, kept for the record |
| `2429b6c` | `MarketMultiplier.t.sol:60,75,109,122,141-142,157` (new file) | all multiplier semantics asserted at `1e12`–`1e15` relative tolerance | the exponent rewrite (`rayPowRay`) is not exact; `1e15` = 0.1 % on a year of growth. Hand mutant H07b (linear instead of exponent) is killed, but a mutant that mis-computes the fractional part by < 0.1 % would not be. |
| `2429b6c` | `WadRayMath.t.sol:202-234` (new) | seven `assertApproxEqRel(…, 1e12)` | the new transcendental helpers have no exact oracle in the suite; no Python/mpmath differential in `test/` |
| `2429b6c` | `Stablecoin.t.sol:341-372` | `previewRedeem` → `convertToAssets` in every curve assertion; `totalAssets` assertions re-pinned from "curve output" to "backing" | `totalAssets` semantics changed (recognised backing, not exit quote) and `previewRedeem` now reverts; the pinned numbers (`37.31…`, `17.24…`) were preserved — good |
| `142ec65` | `AuditSecurity.t.sol`, `FixedExtend.t.sol`, `BaseMarket.t.sol`, `Lender.t.sol` (new) | 20 new `assertGt(x, 0)` / `assertGe(x, 1e27)` style assertions | "Cleanup repo for audit": smoke tests written to touch surface area, all of the not-revert flavour catalogued in §1.1 |
| `e4a7b93` | `DebtLifecycle.t.sol` | deleted `assertLt(healthiness, before)` / `assertGe(healthiness, 1e27)` around an owner `setTranches` removal | `setTranches` became REGISTRY-only (R2-M1 fix); the test that a removal *lowers* health with debt outstanding was removed along with the capability, so the "healthy after membership change" property is now asserted only via the `Unhealthy` revert |
| `a843c1d` | `AccountingIntegrity.t.sol:209-362` (new) | `assertLe(minted, amount)`, `assertLe(repaid, amount)` alongside `assertEq(debt Δ, minted)` | the rounding fix makes `borrow`/`repay` return a *realised* amount ≤ request; the tests assert the new contract (settle what you burn) rather than the old one (settle what you asked) — correct, but note `LendingFlow.t.sol:100,112-113` had to be widened to `assertApproxEqAbs(…, 2)` / `(…, 1)` for the same reason |

No tolerance was widened to hide a failing value; the pattern is rather that the new numerical
code (`rayPowRay`, `_growIndex`, the borrow/repay flooring) was pinned **relatively** rather than
against an independent oracle, so the suite accepts anything within 0.1 %.

### 1.9 What class of bug would this suite fail to catch?

Plainly:

1. **Accrual-ordering and cross-call accounting bugs.** The suite pins single-call arithmetic tightly (borrow mints what it records, repay burns what it clears, a charge mints the reported growth) but almost every scenario calls `chargePremium()` explicitly before the action under test. A path that acts on a stale index — `borrow`, `writeOff` without `_chargePremium()` (Gambit `FloatingMarket#17`, `#29`) — passes 574/574. I16 and I30 have no stateful check.
2. **Partial-amount paths in the fixed market.** Every fixed liquidation/write-off repays `max` or a shortfall larger than half the loan, so `-=` vs `%=` is indistinguishable (`FixedMarket#129`, `#161`). Anything wrong only for small repayments is invisible.
3. **Coverage under mixed junior/senior states.** `lockedValue` is tested where the junior covers all or nothing of the requirement, never a partial split (`BaseMarket#161`, H02); `extend` is never tested with health near 1 (H19); `availableCredit(term)`'s same-window catch-up never binds (H25); the `lt ≤ 1e27` bound is only tested on `Registry.initialize` (H24).
4. **Anything that is *consistently* wrong.** Because the money-flow assertions compare contract views to other contract views (premium quote vs premium minted vs debt growth), a `_premium` or `_growIndex` that is wrong in the same way on both sides passes; only the handful of hard-coded numbers (`1_221.4e18`, `37.31…`) and the `1e12`–`1e15` relative checks stand in the way.
5. **Access-control regressions on roles the harness holds.** With `address(this)` holding every role, a selector accidentally rewired to ADMIN/any-held-role or a `restricted` modifier dropped from a function only `RoleTable`'s snapshot catches, and only for the 58 selectors it lists; the 27 selectors in §1.7 with no negative call would survive a dropped `restricted` on the *positive* side of the suite entirely (Gambit's `restricted`-removal mutants are what §2 measures this with).
6. **Third-party-actor attacks.** No test has two mutually untrusted operators (curator vs market owner vs borrower vs guardian); P1, P8, P9, P12, P13, P14, P17 have no test at all, and P4, P11, P15, P18 are *enshrined* as intended behaviour.
7. **6-decimal underlying and stale-price liveness.** Everything runs at 18 decimals with a 10-year staleness window; the mainnet shape (6-dec USDC, 1-hour feeds) is exercised by five tests.
8. **Numerical accuracy of the new transcendental math.** `rayPowRay/rayLn/rayExp` have no fuzz, no monotonicity, no lower bound and no overflow bound; an error under 1e-12 relative, or any error in the `exp <<= k` range (`k ≥ 1`, i.e. growth factors above `e`), is untested (H17 is killed only because a 10-year warp at 20 % crosses `e`).

---
## 2. Mutation testing

### 2.1 Method

Gambit v1.0.6 (`--solc ~/.svm/0.8.36/solc-0.8.36`, remappings from `foundry.toml`) generated mutants for the 12 money-bearing contracts; ids run to 2,677 (the highest id per contract, listed in §2.2), of which **752** were run, sampled deterministically by id stride per contract so that every function with a division, comparison or external call received at least one mutant. To those were added **29** hand-authored semantic mutants (H01–H28, `hand_mutants.py` in the scratchpad; the exact replacement is the `orig`/`mutant` pair in `tests/mutants/mutation.log`), chosen for the classes §1.9 predicts the suite misses: flipped rounding direction, removed guards and clamps, swapped premium legs, a linear multiplier in place of the exponent, dropped checkpoints.

Each mutant was applied in its own `git worktree` at `a843c1d`, compiled, and run twice: `forge test -q` on the stock `test/` suite (`result_before`) and `FOUNDRY_TEST=audit/v3/tests/mutants forge test -q` on the ten killing-test files written during this workstream (`result_after`). KILLED is a non-zero exit, SURVIVED a zero exit; no mutant was rejected by the compiler. Wall time 13,650 s for 781 mutants (17.5 s each, of which the stock test run itself is 0.9 s; the rest is compilation). The killing tests pass 32/32 on unmutated HEAD (`tests/mutants/README.md` for the run command).

### 2.2 Score

Mutation score = killed / run. The right-hand columns adjust for the residual survivors classified in §2.4 as equivalent (no observable difference) — that classification is by reading, so both figures are given.

| Contract | ids generated (max id) | run | killed, stock suite | killed, + `tests/mutants/` | newly killed |
|---|---:|---:|---:|---:|---:|
| `BaseMarket` | 314 | 80 | 74 (92.5 %) | 77 (96.2 %) | 3 |
| `FloatingMarket` | 138 | 70 | 61 (87.1 %) | 63 (90.0 %) | 2 |
| `FixedMarket` | 329 | 83 | 75 (90.4 %) | 80 (96.4 %) | 5 |
| `Tranche` | 146 | 74 | 72 (97.3 %) | 73 (98.6 %) | 1 |
| `Underwriter` | 138 | 70 | 58 (82.9 %) | 69 (98.6 %) | 11 |
| `Stablecoin` | 310 | 90 | 84 (93.3 %) | 88 (97.8 %) | 4 |
| `InterestRateModel` | 288 | 42 | 40 (95.2 %) | 41 (97.6 %) | 1 |
| `ERC7540AsyncRedeem` | 310 | 90 | 69 (76.7 %) | 81 (90.0 %) | 12 |
| `PremiumVesting` | 229 | 39 | 35 (89.7 %) | 36 (92.3 %) | 1 |
| `WadRayMath` | 149 | 38 | 36 (94.7 %) | 36 (94.7 %) | 0 |
| `Registry` | 265 | 45 | 39 (86.7 %) | 43 (95.6 %) | 4 |
| `Oracle` | 61 | 31 | 30 (96.8 %) | 31 (100.0 %) | 1 |
| Gambit subtotal | 2,677 | 752 | 673 (89.5 %) | 718 (95.5 %) | 45 |
| Hand-authored H01–H28 | — | 29 | 18 (62.1 %) | 28 (96.6 %) | 10 |
| **Total** | — | **781** | **691 (88.5 %)** | **746 (95.5 %)** | **55** |
| Total, 27 equivalents excluded | — | 754 | 691 (91.6 %) | 746 (98.9 %) | |

**Headline: the stock suite scores 88.5 % raw (91.6 % equivalent-adjusted); ten killing-test files with 32 tests raise it to 95.5 % raw (98.9 % adjusted), leaving 8 genuine survivors.** The raw number for the stock suite is respectable and is the wrong thing to look at: the 55 mutants it missed are not spread evenly across operators but concentrate in exactly the classes §1.9 predicted — partial-amount paths in the fixed market, stale-index accrual, the queue's FIFO bookkeeping, the Underwriter's request accounting, coverage arithmetic in `lockedValue`, and guards on roles the harness itself holds. The hand-authored set, built from those predictions, scored 62 % against the stock suite: 11 of 29 deliberate money- or coverage-bearing changes passed 574/574.

### 2.3 Survivors of the stock suite killed by `tests/mutants/`

All 55 mutants that survived the stock suite and are killed by the new tests, grouped by the file that kills them (`README.md` in that directory is the same map). Each line is `id` `file:line` `original → mutant`.

**`FixedPartial.t.sol`**
- `FixedMarket#129` `FixedMarket.sol:158` — ` - ` → `%`
- `FixedMarket#161` `FixedMarket.sol:202` — ` - ` → `%`
- `FixedMarket#138` `FixedMarket.sol:173` — `(liquidityPremium, underwriterPremium) = _premiumStillToMint(chargeabl` → `assert(true)`
- `FixedMarket#114` `FixedMarket.sol:146` — `_totalDebt -= repaid` → `assert(true)`
- `H19` `FixedMarket.sol` — `extend`: post-extension `Unhealthy` check dropped
- `H25` `FixedMarket.sol` — `availableCredit`: same-window catch-up dropped

**`FixedWriteOff.t.sol`**
- `FixedMarket#122` `FixedMarket.sol:157` — `_writeOff(amount)` → `assert(true)`

**`FloatingAccrual.t.sol`**
- `FloatingMarket#17` `FloatingMarket.sol:66` — `_chargePremium()` → `assert(true)`
- `FloatingMarket#29` `FloatingMarket.sol:105` — `_chargePremium()` → `assert(true)`
- `H23` `InterestRateModel.sol` — `updateUnderwriterRate`: index checkpoint dropped

**`Implementations.t.sol`**
- `Tranche#1` `Tranche.sol:43` — `_disableInitializers()` → `assert(true)`
- `Underwriter#1` `Underwriter.sol:60` — `_disableInitializers()` → `assert(true)`
- `Stablecoin#1` `Stablecoin.sol:49` — `_disableInitializers()` → `assert(true)`
- `InterestRateModel#1` `InterestRateModel.sol:68` — `_disableInitializers()` → `assert(true)`
- `Registry#1` `Registry.sol:85` — `_disableInitializers()` → `assert(true)`
- `Oracle#7` `Oracle.sol:26` — `_disableInitializers()` → `assert(true)`

**`LockedValuePartial.t.sol`**
- `BaseMarket#161` `BaseMarket.sol:287` — `value -= capital` → `assert(true)`
- `BaseMarket#162` `BaseMarket.sol:287` — `capital` → `0`
- `H01` `BaseMarket.sol` — `lockedValue`: ceil → floor
- `H02` `BaseMarket.sol` — `lockedValue`: junior-capital subtraction dropped
- `H11` `Tranche.sol` — `Tranche.unlockedSupply`: locked-assets ceil → floor

**`MarketConfig.t.sol`**
- `BaseMarket#10` `BaseMarket.sol:56` — `$.buffer = IRegistry(_registry).buffer()` → `assert(true)`
- `Registry#25` `Registry.sol:110` — `targetHealth = init.targetHealth` → `assert(true)`
- `Registry#79` `Registry.sol:214` — `roleId == type(uint64).max` → `false`
- `Registry#211` `Registry.sol:431` — `IBaseMarket.setBorrowerRole.selector` → `0`
- `H16` `Registry.sol` — `Registry.setBorrowerRole`: `isOperatorRole` check dropped
- `H24` `BaseMarket.sol` — `setLt`: `lt ≤ 1e27` bound dropped

**`RedeemFifo.t.sol`**
- `ERC7540AsyncRedeem#50` `ERC7540AsyncRedeem.sol:138` — `_shares > maxShares` → `false`
- `ERC7540AsyncRedeem#51` `ERC7540AsyncRedeem.sol:138` — `_shares > maxShares` → `maxShares > _shares`
- `ERC7540AsyncRedeem#58` `ERC7540AsyncRedeem.sol:155` — `_shares > maxShares` → `maxShares > _shares`
- `ERC7540AsyncRedeem#120` `ERC7540AsyncRedeem.sol:278` — `maxAssets = convertToAssets(maxInstantRedeem(_owner))` → `assert(true)`
- `ERC7540AsyncRedeem#121` `ERC7540AsyncRedeem.sol:278` — `convertToAssets(maxInstantRedeem(_owner))` → `0`
- `ERC7540AsyncRedeem#176` `ERC7540AsyncRedeem.sol:348` — `currentIndex <= queueIndex` → `false`
- `ERC7540AsyncRedeem#219` `ERC7540AsyncRedeem.sol:389` — `_sortIds(list)` → `assert(true)`
- `ERC7540AsyncRedeem#254` `ERC7540AsyncRedeem.sol:416` — `ids[j] = ids[j - 1]` → `assert(true)`
- `ERC7540AsyncRedeem#260` `ERC7540AsyncRedeem.sol:416` — ` - ` → `%`
- `ERC7540AsyncRedeem#261` `ERC7540AsyncRedeem.sol:416` — ` - ` → `**`
- `ERC7540AsyncRedeem#274` `ERC7540AsyncRedeem.sol:421` — `ids[j] = key` → `assert(true)`
- `ERC7540AsyncRedeem#288` `ERC7540AsyncRedeem.sol:447` — `_shares` → `1`

**`StablecoinGuards.t.sol`**
- `Stablecoin#64` `Stablecoin.sol:161` — `badDebt > totalSupply()` → `false`
- `Stablecoin#86` `Stablecoin.sol:179` — `IInterestRateModel(irm).updateLiquidityRate()` → `assert(true)`
- `Stablecoin#107` `Stablecoin.sol:191` — `unlocked = available` → `assert(true)`
- `H10` `Stablecoin.sol` — `Stablecoin.unlockedSupply`: on-hand cap dropped
- `H21` `Stablecoin.sol` — `recognizeBadDebtInReserve`: `badDebt ≤ totalSupply` guard dropped

**`UnderwriterQueue.t.sol`**
- `Underwriter#17` `Underwriter.sol:111` — `defaultTranche == _tranche` → `true`
- `Underwriter#33` `Underwriter.sol:149` — `shares > balance` → `true`
- `Underwriter#34` `Underwriter.sol:149` — `shares > balance` → `false`
- `Underwriter#37` `Underwriter.sol:149` — `balance` → `0`
- `Underwriter#38` `Underwriter.sol:149` — `balance` → `1`
- `Underwriter#53` `Underwriter.sol:176` — `queuedRequest[tranche][requestId] = recorded - shares` → `assert(true)`
- `Underwriter#54` `Underwriter.sol:176` — `recorded - shares` → `0`
- `Underwriter#57` `Underwriter.sol:176` — ` - ` → `*`
- `Underwriter#58` `Underwriter.sol:176` — ` - ` → `/`
- `Underwriter#61` `Underwriter.sol:176` — `recorded - shares` → `shares - recorded`

**`VestingOptOut.t.sol`**
- `PremiumVesting#55` `PremiumVesting.sol:128` — `!$.optedIn[msg.sender]` → `false`

What these mean, in the order a reviewer would care: `FixedMarket#129`/`#161` (`-` → `%` on a partial repayment) and `#114` pass because every fixed repayment in `test/` is total; `FloatingMarket#17`/`#29` (`_chargePremium()` removed from `borrow`/`writeOff`) pass because every scenario charges premium explicitly first; `BaseMarket#161`/`#162` and H01/H02/H11 (the junior-capital subtraction and the rounding direction of `lockedValue`/`unlockedSupply`) pass because no test sits in a partial junior/senior split; the ten `Underwriter` queue mutants pass because `queuedRequest` bookkeeping is never read back after a partial claim; the twelve `ERC7540AsyncRedeem` mutants pass because the FIFO sort and the `maxRedeem` clamp are exercised with one request at a time; `Registry#79`/`#211`/H16/H24 and `BaseMarket#10` pass because the harness holds every role and never sends a wrong one; the six `#1` mutants pass because no test calls `initialize` on an implementation.

### 2.4 Residual survivors

35 mutants survive both suites. 27 are classified equivalent (no observable difference, or a difference only in the revert selector or in a zero-value event); 8 are genuine gaps, each with the one test that would kill it.

| id | location | original → mutant | class | note |
|---|---|---|---|---|
| `FixedMarket#170` | `FixedMarket.sol:203` | `catchUp >= limit` → `false` | **gap** | when the catch-up exceeds the limit the original returns 0 credit and the mutant underflows (reverts): the R3-M2 corollary (`availableCredit` shrinks under a large floating notional). No test sits in that state. |
| `Tranche#29` | `Tranche.sol:84` | `slashedValue == 0` → `false` | **gap** | dust: with `slashedValue == 0` the original skips the transfer; the mutant moves the `assets` dust (worth < 1 price unit) and still returns 0. No test asserts the dust stays. |
| `Stablecoin#92` | `Stablecoin.sol:188` | `supply > locked` → `true` | **gap** | reachable only when `creditBackedSupply + badDebt > totalSupply` (the B-2 over-recognition state); the mutant underflows where the original returns 0. A test in the B-2 state kills it. |
| `InterestRateModel#22` | `InterestRateModel.sol:94` | `utilizationAverage.lastUpdate = block.timestamp` → `assert(true)` | **gap** | with `lastUpdate == 0` the first EMA observation carries full weight; the original keeps the zero average until one averaging period after deploy. No test reads `averageUtilization()` inside the first period. |
| `ERC7540AsyncRedeem#211` | `ERC7540AsyncRedeem.sol:378` | `_assets != 0` → `false` | **gap** | 4-arg `withdraw` of an asset amount that converts to 0 shares: the original reverts `InexactPayout`, the mutant returns 0 having paid nothing. No test withdraws below one share. |
| `ERC7540AsyncRedeem#37` | `ERC7540AsyncRedeem.sol:104` | `$.controllerRequests[from].remove(_requestId)` → `assert(true)` | **gap** | view-level: `transferRequest` leaves the id in the old controller's set; `_requestShares(id, from)` is 0 so nothing is claimable, but `pendingRequests(from)` over-reports and `_claimFifo` sorts a longer list (the R3-M4 cost). A test asserting the old set shrinks kills it. |
| `Registry#115` | `Registry.sol:290` | `_assets.length == 0` → `false` | **gap** | unclassified: a 0-tranche market reaches `_setTranches` with `totalWeight == 0`; whether that reverts is asserted nowhere. One negative test kills it. |
| `H20` | `FixedMarket.sol` | fixed `borrow`: post-borrow `Unhealthy` check dropped | **gap** | reachable only at `ltv == lt − buffer`, where `_creditCheck` passes and the first premium wei pushes health below 1 (A-3); no test sits at that boundary. |
| `BaseMarket#1` | `BaseMarket.sol:39` | `_disableInitializers()` → `assert(true)` | **equivalent** | `_disableInitializers` is called in both the abstract `BaseMarket` constructor and each concrete market constructor; removing one copy changes nothing (report Appendix A lists the duplication). |
| `BaseMarket#233` | `BaseMarket.sol:395` | `_tranches[i].tranche == address(0)` → `false` | **equivalent** | error-site only: `ITranche(address(0)).market()` reverts on the next line, without the `ZeroAddress` selector. |
| `BaseMarket#297` | `BaseMarket.sol:457` | `premium == 0` → `false` | **equivalent** | zero-value only: the mutant calls `fund(0)`/mints 0 (Appendix A: `fund(0)` succeeds and emits). |
| `FloatingMarket#1` | `FloatingMarket.sol:34` | `_disableInitializers()` → `assert(true)` | **equivalent** | as BaseMarket#1. |
| `FloatingMarket#113` | `FloatingMarket.sol:184` | `block.timestamp` → `0` | **equivalent** | as #13. |
| `FloatingMarket#114` | `FloatingMarket.sol:184` | `block.timestamp` → `1` | **equivalent** | as #13. |
| `FloatingMarket#13` | `FloatingMarket.sol:44` | `block.timestamp` → `0` | **equivalent** | `lastPremiumUpdate` is read only by the same-block early returns at `:140`/`:171`; a wrong value re-runs an idempotent index read (gas only). |
| `FloatingMarket#14` | `FloatingMarket.sol:44` | `block.timestamp` → `1` | **equivalent** | as #13. |
| `FloatingMarket#49` | `FloatingMarket.sol:140` | `lastPremiumUpdate == block.timestamp` → `false` | **equivalent** | same-block early return; `premiumIndices()` recomputed in the same block equals the stored indices (the R3-M2 verifier showed the guard is gas-only). |
| `FloatingMarket#98` | `FloatingMarket.sol:171` | `lastPremiumUpdate == block.timestamp` → `false` | **equivalent** | as #49. |
| `FixedMarket#1` | `FixedMarket.sol:41` | `_disableInitializers()` → `assert(true)` | **equivalent** | as BaseMarket#1. |
| `FixedMarket#146` | `FixedMarket.sol:199` | `prior > 0` → `true` | **equivalent** | with `prior == 0`, `catchUp == 0` and `limit` is unchanged; gas only. |
| `Underwriter#138` | `Underwriter.sol:305` | `block.timestamp` → `1` | **equivalent** | informational: `lastReported` has no consumer in `contracts/` (getter only). |
| `Stablecoin#303` | `Stablecoin.sol:324` | `reduced > badDebt` → `false` | **equivalent** | unreachable: `StablecoinGuards.t.sol` carries the evidence (`_shares − paidInShares ≤ badDebt` on every path). |
| `ERC7540AsyncRedeem#169` | `ERC7540AsyncRedeem.sol:342` | `unlocked == 0` → `false` | **equivalent** | as #99. |
| `ERC7540AsyncRedeem#233` | `ERC7540AsyncRedeem.sol:400` | `remainingUnlocked -= take` → `assert(true)` | **equivalent** | redundant: `remainingUnlocked` is already bounded by the `_shares ≤ unlocked` pre-check at `:435` and by `remaining`. |
| `ERC7540AsyncRedeem#282` | `ERC7540AsyncRedeem.sol:435` | `_shares > unlocked` → `false` | **equivalent** | as #57. |
| `ERC7540AsyncRedeem#57` | `ERC7540AsyncRedeem.sol:155` | `_shares > maxShares` → `false` | **equivalent** | redundant pair with #282: `redeem` checks `maxRedeem` (`:155`) and `_claim` re-checks `unlocked` (`:435`); removing either alone leaves the other. Removing both is caught by `RedeemFifo.t.sol`. |
| `ERC7540AsyncRedeem#71` | `ERC7540AsyncRedeem.sol:177` | `consumed != shares` → `false` | **equivalent** | unreachable: `_claimFifo` returns exactly `shares` or reverts (report Appendix A, `IncompleteClaim` outer checks). |
| `ERC7540AsyncRedeem#8` | `ERC7540AsyncRedeem.sol:76` | `balanceOf(_owner) < _shares` → `false` | **equivalent** | error-site only: the escrow transfer below reverts with the same `ERC20InsufficientBalance`. |
| `ERC7540AsyncRedeem#99` | `ERC7540AsyncRedeem.sol:233` | `unlocked == 0` → `false` | **equivalent** | gas early-return: with `unlocked == 0` the arithmetic below returns 0. |
| `PremiumVesting#121` | `PremiumVesting.sol:241` | `amount > 0` → `true` | **equivalent** | adds `mulDiv(0, …) == 0`. |
| `PremiumVesting#187` | `PremiumVesting.sol:304` | `amount > 0` → `true` | **equivalent** | as #121. |
| `PremiumVesting#73` | `PremiumVesting.sol:151` | `premium == 0` → `false` | **equivalent** | zero-value only: transfers 0 and emits. |
| `WadRayMath#117` | `WadRayMath.sol:155` | `x == 0` → `false` | **equivalent** | shortcut: the series at `x == 0` returns `RAY`; gas only. |
| `WadRayMath#25` | `WadRayMath.sol:115` | `exp == 0 \|\| base == RAY` → `false` | **equivalent** | shortcut: the general path at `exp == 0` / `base == RAY` is `rayExp(0)` / `rayExp(rayLn(RAY)·e) = rayExp(0) = RAY`; gas only. |
| `Registry#199` | `Registry.sol:416` | `manager.setTargetFunctionRole(underwriterBeacon, beaconSelec` → `assert(true)` | **equivalent** | in effect: an unwired `upgradeTo` selector on the underwriter beacon resolves to ADMIN(0) by omission, which is the role the line sets (E-4). |

### 2.5 Hand-authored mutants

| id | change | stock suite | + `tests/mutants/` |
|---|---|---|---|
| H01 | `lockedValue`: ceil → floor | SURVIVED | KILLED |
| H02 | `lockedValue`: junior-capital subtraction dropped | SURVIVED | KILLED |
| H03 | `_writeOff`: cap `min(debt, recoverableDebt)` → `debt` | KILLED | KILLED |
| H04 | `liquidate`: `Healthy()` guard dropped | KILLED | KILLED |
| H05 | tranche eligibility `totalCapital() > 0` → always eligible | KILLED | KILLED |
| H06 | floating premium split: liquidity and underwriter legs swapped | KILLED | KILLED |
| H07a | `_growIndex`: `rayPowRay` → `rayMul` (linear in the multiplier) | KILLED | KILLED |
| H07b | `_growIndex`: exponent → first-order `RAY + growth·multiplier` | KILLED | KILLED |
| H08 | `_claimableShares`: unlocked clamp dropped | KILLED | KILLED |
| H09 | curve inverse: retained-term denominator altered | KILLED | KILLED |
| H10 | `Stablecoin.unlockedSupply`: on-hand cap dropped | SURVIVED | KILLED |
| H11 | `Tranche.unlockedSupply`: locked-assets ceil → floor | SURVIVED | KILLED |
| H12 | `Tranche.slash`: price conversion skipped (`slashedValue = value`) | KILLED | KILLED |
| H13 | `FixedMarket` catch-up: `prior == 0` → `prior >= 0` (never applied) | KILLED | KILLED |
| H14 | `variableCreditLimit`: `min(ltv, lt)` → `ltv` | KILLED | KILLED |
| H15 | `Underwriter._mark`: loss never recognised | KILLED | KILLED |
| H16 | `Registry.setBorrowerRole`: `isOperatorRole` check dropped | SURVIVED | KILLED |
| H17 | `rayExp`: `exp <<= k` range reduction dropped | KILLED | KILLED |
| H18 | `PremiumVesting`: `remainder -= amount` dropped | KILLED | KILLED |
| H19 | `extend`: post-extension `Unhealthy` check dropped | SURVIVED | KILLED |
| H20 | fixed `borrow`: post-borrow `Unhealthy` check dropped | SURVIVED | SURVIVED |
| H21 | `recognizeBadDebtInReserve`: `badDebt ≤ totalSupply` guard dropped | SURVIVED | KILLED |
| H22 | floating `liquidate`: `min(amount, maxLiquidatable())` dropped | KILLED | KILLED |
| H23 | `updateUnderwriterRate`: index checkpoint dropped | SURVIVED | KILLED |
| H24 | `setLt`: `lt ≤ 1e27` bound dropped | SURVIVED | KILLED |
| H25 | `availableCredit`: same-window catch-up dropped | SURVIVED | KILLED |
| H26 | `_onWithdraw`: bad-debt reduction ignores paid shares | KILLED | KILLED |
| H27 | `Tranche`: `assets > total` clamp dropped | KILLED | KILLED |
| H28 | `_chargePremium`: senior branch always active | KILLED | KILLED |

### 2.6 Reading

1. **The score is high where the arithmetic is single-call and low where state carries across calls.** `Tranche` (97.3 %), `Oracle`, `InterestRateModel` and `Stablecoin` are pinned tightly; `ERC7540AsyncRedeem` (76.7 %) and `Underwriter` (82.9 %) — the two contracts whose correctness is a property of sequences — are the weakest, and they are also where round 1's H-2 and round 3's R3-M4/R3-H5 live.
2. **Guards the harness cannot trip survive.** With the test contract holding every role, a dropped `isOperatorRole`, `lt ≤ 1e27` or `_disableInitializers` is invisible (11 of the 55 flips). §1.7's recommendation (a second, unprivileged actor in the harness) is the cheapest fix for the whole class.
3. **The ten killing files are candidates for `test/`.** They are written against the stock `CapDeployer`, pass on HEAD, and add 32 tests for 55 previously invisible mutants. `FixedPartial.t.sol`, `LockedValuePartial.t.sol` and `RedeemFifo.t.sol` cover the three classes that map onto open findings.
4. **What mutation testing did not measure.** Gambit's operators are local (operator swaps, deletions, constant replacement); none of the round-3 Mediums is a local mutation of a correct program, they are missing checks and missing refreshes, which no mutant can introduce. The hand-authored set approximates that (H10, H15, H21, H23 are "missing check" mutants) and is where the stock suite did worst.
