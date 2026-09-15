# Cap v2 — Security, Mathematical and Economic Audit, Round 3

**Target:** branch `cap-network`, commit `a843c1d` ("Fix rounding issues", 2026-09-14). Prior rounds: round 1 at `3c45dca`, round 2 at `3dad5ef` (deliverables on branch `cap-network-audit` @ `a3308e0`).
**Date:** 2026-09-14. **Deliverables:** this report, `00-plan.md`, `test-suite-assessment.md`, `findings/` (per-workstream files, `REGRESSION.md`, `verify/` verdicts), `tests/` (87 Foundry files, 393 tests and invariants), `models/` (9 Python models with captured output).

## Status of the environment and the process

Nothing in the repository failed to build, and every tool the brief asked for installed: Foundry 1.6.0-nightly, solc 0.8.36, OZ 5.7.0 byte-identical to the registry tarball, slither 0.10.4, Gambit v1.0.6, halmos 0.3.3, universalmutator, Python 3.11 with numpy/scipy/mpmath. `ETH_RPC_URL` is unset; on-chain checks used `https://ethereum-rpc.publicnode.com`. Two ambiguities in scope are resolved by Matt's answers and stated in `00-plan.md` §2: curators and market owners are third parties, and the live mainnet cUSD/stcUSD proxies will be upgraded to this code.

Process note: six subagents were terminated mid-task by a spend limit and relaunched; two of them (math, mutation) had written their principal deliverable before termination, and the relaunched agents completed the remainder. Every number in this report is either pasted from a test/model log under `audit/v3/` or marked as pending.

---

## 1. Executive summary

**What a firm would open with.** The code has been written as a fresh deployment while the plan is to upgrade two live proxies holding ~84.9 M cUSD and ~74.7 M stcUSD. There is no migration entry point: `Stablecoin.initialize` and `Wrapper.initialize` are `initializer`-gated and both live proxies already sit at `Initializable` version 1, no `reinitializer` exists, the new `AccessManaged` namespace is unwritten so every `restricted` function including `_authorizeUpgrade` reverts, and the Wrapper's `optIn()` (its only path to earning premium) lives in that same unreachable initializer. A bare `upgradeTo` bricks both tokens irreversibly. A two-step path through an out-of-tree migrator implementation exists today, which is why this is High and not Critical, but nothing in the repo implements, scripts or tests it, and the live reserve (61.5 M USDC lent to v1 agents, 18.3 M in a v1 ERC-4626 vault, 5.1 M wWTGXX) can only be brought into the new contract by steps that exist nowhere in the repo (v1 repayments, a follow-up implementation that redeems the FR shares, a wind-down of the wWTGXX basket). Until a migration is designed and fork-tested, an external firm cannot meaningfully audit the upgrade, and a firm that discovers this from the config file will open with it.

**What blocks an external audit** (in order):
1. A written, fork-tested migration for the live proxies (§5, R3-H1, R3-M6, U-4).
2. A decision on the trust stance for curators and market owners. Two Highs carried from prior rounds (curator `addTranche` drain, stale underwriter mark) were left in place with NatSpec declaring them intended. Under the stance Matt confirmed, they are open coverage defects, and the round-1 systemic pattern ("numbers consumed without a freshness contract") is unchanged.
3. A trust-model document. The repository has none; the README is build instructions. §3 of this report is the model derived from code and should be the starting point.
4. A stateful invariant suite in `test/`. There are 574 unit tests and zero invariants; the suite pins the mirror (an 18-decimal underlying, 10-year feed staleness, a test contract holding every role) rather than the product. Mutation score 88.5 % raw / 91.6 % adjusted for the stock suite, 95.5 % / 98.9 % after the ten killing-test files (§8).

**Counts after adversarial verification** (round-3-new findings verified by a fresh subagent each; carried findings re-verified by WS-R with ported tests):

| Severity | New in round 3 | Carried and still open | Total |
|---|---|---|---|
| Critical | 0 | 0 | 0 |
| High | 1 (R3-H1 live-proxy upgrade has no migration entry point; bare upgrade bricks both tokens) | 2 (R2-H1 curator drain, H-1 stale mark) | 3 |
| Medium | 6 (R3-M1 dead feed bricks repay, R3-M2 fixed premium catch-up/sandwich, R3-M3 loss-recognition front-run, R3-M4 request-flood DoS, R3-M5 staker yield above borrow rate, R3-M6 stcUSD opt-in omitted by any migration that forgets it) | 2 (M-2 EMA park, M-3 JIT premium; M-4 merged into R3-M3) | 8 |
| Low | 20 | 13 | 33 |
| Informational | 27 | 4 | 31 |

Fixed since round 2 and re-confirmed: M-5, R2-M1, R2-M2, L-1, L-3, L-4, L-8, L-9, L-11, L-18, R2-L1, R2-L6, R2-L7 (14 items); C-1, L-2, L-7, L-17 still fixed. No regressions.

**Round-3 systemic observation** (§10): every loss-bearing state in the protocol is refreshed only by a discretionary privileged transaction (GUARDIAN write-off / reserve recognition, KEEPER report / extendAdmin, LIQUIDATOR liquidate, GOVERNOR setSource), and every one of those transactions is front-runnable by the party it would charge. The contracts enforce coverage at the instant a check runs; between checks, the party that moves first takes the surplus.

---

## 2. Scope and methodology

Scope, toolchain and baseline are recorded in `00-plan.md` §1–2: 21 contracts (4,427 lines) under `contracts/`, interfaces read for intent, OZ 5.7.0 and the Aave-derived halves of `WadRayMath`/`MathUtils` verified unmodified and excluded, `script/` read for role wiring only, v1 `main@695c828` read for the upgrade workstream.

Method: one planning pass (invariants I1–I40, hypotheses P1–P22, trust model), nine parallel workstreams (A math, B external callers, C coverage, D liquidations/oracles, E access/reserves/upgrades, U live-proxy compatibility, F test suite and mutation, G economic models, R regression), a lead pass on the trust model and rate economics, then one adversarial verification subagent per new Critical/High/Medium given the code and the finding text only. Verdicts are in `findings/verify/`; nothing below is reported at a severity its verifier did not confirm.

Proof standard: every Medium and above has a Foundry test under `audit/v3/tests/` that fails on `a843c1d` and whose output is pasted in the workstream file, or a model whose script reproduces the number. Techniques are labelled per claim: halmos (symbolic), fuzz with run count, exact-integer Python vs `mpmath`, or code reading.

Run commands: `FOUNDRY_TEST=audit/v3/tests/<dir> forge test --match-path 'audit/v3/tests/<dir>/*' -vv` (the env var is required; `foundry.toml` is untouched). Models: `<venv>/bin/python audit/v3/models/<script>.py`.

---

## 3. Trust model as derived from code

The full role table with every selector is `00-plan.md` §4 and `findings/E-roletable.md` (153 rows, regenerated programmatically from the deployed AccessManager). The parts that matter for risk:

- **ADMIN (role 0)** is held permanently by the Registry and by `users.admin` (defaults to the broadcast wallet). It can upgrade every UUPS contract and every beacon. Seventeen `restricted` selectors resolve to ADMIN by omission rather than by wiring, including all seven `upgradeToAndCall`s and the Registry's own (E-4). A Registry upgrade is a full protocol takeover (E-3).
- **GOVERNOR** sets the oracle sources (the de-facto asset whitelist), the rate curve, the liquidation bonus, `fixedCreditLimit` per market and the reserve vault. `fixedCreditLimit` defaults to zero, so no market can mint credit until GOVERNOR sizes it. This is the only throttle on credit creation, and it is a per-market USD notional with no per-asset dimension.
- **GUARDIAN** recognises losses (`writeOff`, `recognizeBadDebtInReserve`) and can tighten `lt`/`buffer`. Both loss paths are discretionary and visible in the mempool before they land.
- **KEEPER** moves the reserve to Aera with no cap, rolls expired fixed loans, and refreshes underwriter marks. **LIQUIDATOR** is the only address that can liquidate.
- **WHITELISTED** (never granted by the deploy script) can mint operator roles for itself and create markets and underwriters. A market owner then controls collateral composition (`createTranche` with any GOVERNOR-priced asset), `ltv` up to `lt − buffer`, tranche weights, the underwriter rate, the borrower set and the depositor allowlist (which it may set to PUBLIC, E-5). A curator controls which addresses get ERC-6909 operator rights over the underwriter's whole balance (C-1).
- **Permissionless:** `Vault` deposit/withdraw/transfer, cUSD deposit/mint/fund/coverBadDebt and every ERC-7540 request/claim/transfer, `optIn`/`optOut`/`claim`, floating `repay`/`chargePremium`, fixed `repay`, `updateLiquidityRate`, all of `Wrapper`.

**Deviations from what the code and config say about themselves:**
- `IUnderwriter` NatSpec: the curator "is expected to be held by a timelock or secure multisig" and "is trusted to name a real protocol tranche". Matt: curators are third parties. The contract enforces nothing (C-1).
- `IUnderwriter.report` NatSpec: the stale mark "is intentional, not a live NAV walk". Under the third-party stance that is the defect, not the mitigation (C-2).
- `config/README.md` calls mainnet cUSD/stcUSD "existing proxies" and labels a v1 AccessControl contract as the timelock; the real upgrader is `TimelockController 0xD8236031…` (1-day delay, proposer = 3/5 Safe). `Deploy.s.sol` deploys fresh CREATE3 proxies and overwrites the config (U-6).
- The audit brief's premise that underwriter collateral is restaked (Symbiotic/EigenLayer) and correlated does not apply: no restaking code exists; collateral is plain ERC-6909 balances in `Vault` (C-7). Correlation enters only through shared collateral assets and the shared cUSD.
- Liquidation is permissioned, with no fallback. The protocol's promise ("depositors are protected by contract, not trust") reduces in practice to: GOVERNOR sizes a notional, the owner chooses what backs it, and four privileged addresses must act promptly when it goes wrong.

---

## 4. Regression of round-1 and round-2 findings

Full table with ported tests and pasted output: `findings/REGRESSION.md` (R1: 41 pass / 27 fail across 68 tests; R2: 12 / 6 across 18; a failing test reproduces the finding).

| Status | Findings |
|---|---|
| OPEN, unchanged | **H-1** stale underwriter mark (High; strengthened by C-2's entry leg), **R2-H1** curator drain (High), M-2 EMA park (−24.4 % premium for 1 h of parked capital, G-4), M-3 JIT premium (19.7 % of a 30-day premium for 6 h), M-4 recognition lag (par exit 10,000 vs 8,182 on the curve; now the same class as R3-M3), L-5, L-6, L-10, L-12, L-14, L-15/R2-L2, L-16, L-19, L-20, **L-21 (suggest Medium: owner zeroes the underwriter rate with 714e18 locked)**, R2-L4, R2-L5 |
| CHANGED | **H-2** queue over-credit: the drain is gone (3/3 round-1 tests pass; 48k handler calls in WS-B with no over-claim); residual is view-level (Σ advertised claimable exceeds unlocked, second claimant reverts) — Low. **R2-H2** Aera loss: `recognizeBadDebtInReserve` and the on-hand cap exist, but the loss is still invisible until GUARDIAN acts and a redeemer exits at par (500 vs fair 450) — restated as R3-M3. **M-1** dead feed: narrower (empty tranche or debt-free market escapes) but wider on the repay side — restated as R3-M1. **R2-L3** half fixed (64-byte check; same feed twice still squares the price). |
| FIXED | M-5 (`a843c1d`), R2-M1 (`e4a7b93`), R2-M2 (`142ec65`), L-1, L-3, L-4, L-8, L-9, L-11, L-18, R2-L1, R2-L6, R2-L7; C-1, L-2, L-7, L-17 re-confirmed |
| REGRESSED | none |

---

## 5. Findings by severity

Finding IDs are `R3-<sev><n>` for the ranked list; the source workstream ID and the verifier's verdict are given so the full text, PoC and verdict can be found in `findings/<WS>.md` and `findings/verify/<ID>.md`.

### High

#### R3-H1 — The live cUSD and stcUSD proxies have no migration entry point; a bare upgrade to this code bricks both irreversibly (U-1 + U-2, verified High; Critical if executed as a bare upgrade)
**Location:** `contracts/cap/Stablecoin.sol:L53-L74` (`initialize`, `initializer`), `contracts/cap/Wrapper.sol:L37-L47`; OZ `AccessManagedUpgradeable.authority()` / `AuthorityUtils.canCallWithDelay`.
**Impact:** Verified on a mainnet fork of the real proxies (block 25,976,879 and 25,977,014) and offline with v1 bytecode: both proxies hold `_initialized == 1` (v1 is OZ 5.4.0, same namespaced slot), so `initialize` reverts `InvalidInitialization()`. After `upgradeToAndCall(impl, "")`, cUSD has `asset()==0`, `underlyingDecimals==0`, `irm==0`, `stablecoin()==0`: every deposit, redeem and claim reverts, `previewDeposit(1 USDC) == 1e24`, `requestRedeem` still works and strands shares. `authority()` reads a namespace v1 never wrote, so `canCallWithDelay` on `address(0)` returns unauthorized and every `restricted` function including `_authorizeUpgrade` and `setAuthority` reverts for everyone: the brick cannot be undone from inside the contract.
**Likelihood:** Certain if the upgrade is executed as the code stands. The v1 `_authorizeUpgrade` authorises any implementation, so a two-step upgrade (v1 → migrator that writes the OZ namespaces and calls `optIn` → HEAD) recovers both proxies; that path is not implemented, scripted or tested anywhere in the repo.
**Proof:** `tests/scratch/U/U_LiveUpgrade.t.sol` (8 `test_FAIL_*` on the fork), `U_LocalUpgrade.t.sol` (offline, v1 artifacts etched), verifier's `tests/scratch/verify/U-1/U1_Verify.t.sol` and `U-2/U2_Verify.t.sol` (6 + 3 pass, including the migrator recovery path).
**Recommendation:** Add `reinitializer(2)` entry points on both contracts that run `__AccessManaged_init`, `__PremiumVesting_init(asset, name(), symbol(), this)`, set `underlyingDecimals`/`irm`/`reserveVault`, and on the Wrapper call `optIn()`; execute them inside `upgradeToAndCall` in one timelock batch, cUSD first; add a fork test to `test/`. Or deploy fresh proxies as `DeployInfra.sol` already does and migrate balances.
**Invariant broken:** none listed; the upgrade was out of the invariant suite's scope.

#### Merged into R3-H1 after verification
- **stcUSD opt-in** (U-3, verified **Medium**, listed as R3-M6 below): `Wrapper.initialize` is the only `optIn()` call site; any migration that sets the namespaces but forgets `optIn` leaves 74.7 M stcUSD (holding 80.7 M cUSD) earning nothing while any single opted-in cUSD holder takes the whole liquidity premium. The omission fails silently (wrapper deposits and redeems keep working; `claimable(stcUSD) == 0` so the share price is unchanged) and is repairable by a further upgrade, after which the frozen premium vests. The migration fork test must assert `optedIn(stcUSD)` and a non-zero `claimable`. The ~11 k cUSD "step at upgrade" is the v1 `StakedCap` un-notified profit snapshot (6,662 cUSD plus the running vest at the verifier's block); `notify()` before the batch zeroes it.
- **Reserve not on hand** (U-4, verified **Low**, migration checklist): `totalAssets() > on hand` is HEAD's documented design (`IStablecoin.sol:L154-L158`, asserted by `test/unit/cap/Stablecoin.t.sol:L921`) and `unlockedSupply` caps every exit at what is on hand, so there is no value loss; with authority set the proxy stays upgradeable and a one-off follow-up implementation redeems the FR shares and sweeps wWTGXX (verifier: 3,219 → 21,488 USDC on hand in test). Genuine remaining items: HEAD cannot represent v1 loans (`utilizationRate() == 0` with 61.5 M out), redemptions are par-FIFO against on-hand until the reserve arrives, and the wWTGXX re-denomination is a real wind-down step. Migration order in `findings/U.md` §4.

#### R3-H2 — A curator registers any contract as a "tranche" and moves 100 % of the underwriter's vault balance (C-1; R2-H1 carried; re-verified by WS-R on production wiring)
**Location:** `contracts/cap/Underwriter.sol:L90-L100` (`addTranche` → `IVault.setOperator(_tranche, true)` and `IPremiumVesting(_tranche).optIn()` on an unchecked address), `L103-L116` (`removeTranche` now silently clears the flag on a fake).
**Impact:** From a single WHITELISTED grant, through the Registry: `createChildRoles` → `createUnderwriter(curator = self)` → depositors deposit → `addTranche(attacker contract)` → `Vault.transferFrom(underwriter, attacker, asset, all)`. 1,500e18 of 1,500e18 idle leaves; with 1,000 allocated and 350 of debt, 1,000 of 1,500 leaves (the curator also administers the allocator role and `deallocate`s first; only market-locked capital stays). The only change since round 2 is NatSpec declaring the curator trusted.
**Likelihood:** Curator role only (any WHITELISTED address mints one); cost is gas. Under Matt's stance this is a third party.
**Proof:** `tests/scratch/C/C1_CuratorDrain.t.sol` (3 fail), `tests/scratch/R2/R2_H1_CuratorDrain.t.sol` (2/4 fail, incl. the WHITELISTED-only path).
**Recommendation:** `Registry.isTranche[addr]` check in `addTranche`, and replace blanket ERC-6909 operator rights with a per-allocation allowance (`approve(tranche, id, amount)` inside `_allocate`). Second-order: `removeTranche` then has nothing to revoke.
**Invariant broken:** I25.

#### R3-H3 — Underwriter share price is a stale cache: exits after a slash are over-paid and entries are over-charged, including inside the very `deposit` that refreshes the book (C-2; H-1 carried, verified High)
**Location:** `contracts/cap/Underwriter.sol:L243-L245` (`totalAssets = vault balance + totalDebt` cached), `L187-L203` (`_mark`, only on allocator/keeper action), `L282-L288` (`_transferIn` → `_allocate` → `_mark` after `previewDeposit` has priced the shares).
**Impact:** Exit leg: after an 18.5 % slash on the tranche, Alice `instantRedeem`s and is paid 500.0 vs fair 407.3; the 92.7 comes one-for-one from Bob. Entry leg (new): Carol deposits 100 with a default tranche set; `super.deposit` quotes shares on the stale book, then `_allocate → _mark` realises the loss in the same call, and she holds 83.14 when it returns (verifier re-derived: loss `d·L/(A+d)`, bounded by the slash amount `L`, single-victim when a default tranche is set; `mint` leg identical). No unprivileged re-mark exists.
**Likelihood:** Any holder for the exit leg; any honest depositor for the entry leg; window closes only on a KEEPER `report` or allocator action, which the slash does not trigger. Cost: gas.
**Proof:** `tests/scratch/C/C2_StaleMark.t.sol` (4 fail), `tests/scratch/R1/H1_StaleMark.t.sol` (0/3 pass), verifier's `tests/scratch/verify/C-2/C2_Verify.t.sol` (7 pass, asserting the bug's shape).
**Recommendation:** Mark before pricing: in `Underwriter.deposit/mint/instantRedeem/instantWithdraw/requestRedeem/_claim`, run `_mark` on every registered tranche (or on the tranches with `balanceOf > 0`) before `previewDeposit`/`convertToAssets`. The gas cost is one `convertToAssets` per registered tranche. Alternatively expose a permissionless `report`.
**Invariant broken:** I37 as an exchange-rate property (book ≥ live always holds; equality at conversion time is what pricing needs).

### Medium

#### R3-M1 — One dead feed on a funded, staked tranche bricks the market, including floating `repay` (D-1; M-1 carried and widened; verified Medium)
**Location:** `contracts/cap/market/BaseMarket.sol:L482-L485` (`_earnsPremium` → `totalCapital()` → `Tranche.getPrice()` reverts `InvalidPrice`), `L292-L297`, `L435-L475`; `contracts/cap/market/FloatingMarket.sol:L75-L80`, `L170-L185`.
**Impact:** While any tranche with `stakedSupply > 0` and assets has a stale/zero/reverting feed (both sources), `healthiness`, `maxLiquidatable`, `liquidate`, `writeOff`, `borrow`, `lockedValue`, senior `unlockedSupply` revert (round-1 list), and new on HEAD: floating `repay`, `chargePremium`, `setMarketMultiplier` revert too, because `_chargePremium` prices every staked tranche. Debt compounds through the outage; borrowers cannot reduce it. Round-2 mitigations (empty tranche, zero-lock exit) do not cover this case. Verifier's correction: the dead tranche's stakers can `optOut()` (no price consulted), which restores `repay`/`chargePremium` only; `liquidate`/`writeOff`/`borrow` stay bricked until GOVERNOR `setSource`. The test harness's 3650-day staleness hides all of this from `test/`.
**Likelihood:** One feed outage longer than its staleness window, on any market with more than one asset. A market owner picks the assets (`createTranche`), so a third party can add the fragile feed.
**Proof:** `tests/scratch/D/D5_P11_DeadFeed.t.sol::test_FAIL_borrowerCanRepayDuringOutage` (`InvalidPrice()`), verifier's `tests/scratch/verify/D-1/V_D1_DeadFeedRepay.t.sol` (6 pass).
**Recommendation:** `_earnsPremium` should test `totalAssets() > 0` (no price needed), which matches its own NatSpec; require a secondary source per asset at `setSource`; consider a bounded last-price fallback for the liquidation path only.
**Invariant broken:** I5 (coverage-or-remedy) during the outage.

#### R3-M2 — A fixed draw is charged the rate catch-up on floating notional that already reprices through its own index, and a transient floating draw around a victim's fixed draw raises the victim's premium at near-zero cost (LEAD-2 / G-2; verified Medium)
**Location:** `contracts/cap/market/FixedMarket.sol:L337-L351` (`_borrowPremium`), `L186-L208` (`availableCredit(term)`); `contracts/cap/InterestRateModel.sol:L220-L239` (`unsmoothedCredit`, `averageUtilizationAfterMint`).
**Impact:** Honest case: with 500k of floating credit drawn in the averaging window, a 500k/30-day fixed draw pays 11,472.60 vs 11,130.14 once the same credit is absorbed (+342.47, +3.1 %). The floating loan's index already accrues at the higher utilization the moment the fixed draw lands (`_mintCreditBacked` → `updateLiquidityRate`), so the pot is paid `C·T·Δr` twice. Adversarial case: attacker draws 2M floating, victim draws 500k fixed, attacker repays 12 seconds later: attacker pays 0.214 cUSD, victim pays 12,271.69 instead of 10,787.67 (+13.8 %). Verifier's split: 913.24 of the 1,484.02 is the victim priced at `util(C+P)` because `averageUtilizationAfterMint` adds unabsorbed credit in full (EMA bypass on the up side), 570.78 is the catch-up. Surplus goes to opted-in stcUSD holders only. Overcharge reaches +47 % across the kink (10M line vs 2M reserve). Corollary: the sandwich shrinks `availableCredit(term)` so a pre-sized maximum draw reverts `InsufficientLiquidity` (zero-cost DoS on fixed borrowing); `borrow` has no `maxPremium` guard.
**Likelihood:** Honest overcharge on every fixed draw that shares a window with floating draws. Adversarial: any borrower-role holder with an unused floating line; no bundle needed.
**Proof:** `tests/scratch/LEAD/Expected.t.sol::Expected_P6` (fails: `12271689497716894977169 != 10787671232876712328766`), `P6_FixedCrossNotional.t.sol`, verifier's `tests/scratch/verify/LEAD-2/LEAD2_Verify.t.sol` (7 pass), `models/rate_sweep.py` §6 ($17,123 on a $10M/30d draw vs a $50M sandwich).
**Recommendation:** Track unsmoothed *fixed* credit separately in the IRM and use it for both the catch-up and the `availableCredit(term)` deduction; add a caller-supplied `maxPremium` to `borrow`/`borrowMore`/`extend`. Dropping the same-timestamp early return in `FloatingMarket._chargePremium` does not help (zero elapsed time is zero growth).
**Invariant broken:** none listed; new: a borrower's premium depends only on its own notional and the market state, not on same-window notional that reprices on its own.

#### R3-M3 — Loss recognition is a discretionary, visible GUARDIAN transaction; until it lands every surface quotes par, so the first holders to exit are whole and the rest absorb the loss (E-1; R2-H2 residual and M-4 carried; verified Medium)
**Location:** `contracts/cap/Stablecoin.sol:L152-L156` (`recognizeBadDebtInReserve`), `L159-L167`, `L184-L192` (`unlockedSupply`), `L236-L261` (par branch when `badDebt == 0`), `L102-L117` (`invest`/`recall`, uncapped, unrecorded); `contracts/cap/market/BaseMarket.sol:L380-L386` (`_writeOff`, GUARDIAN).
**Impact:** Reserve leg: 3 holders × 100, Aera loses 90, `recall(210)`; holder 1 `instantRedeem`s at par (100), GUARDIAN recognises, holders 2 and 3 receive 39.03 and 70.97 (pro-rata would be 70 each). Credit leg (M-4): `unrecoverableDebt() > 0` is public but `badDebt` moves only on `writeOff`; par exit 10,000 vs 8,182 on the curve. `invest(all)` drops `unlockedSupply` to 0 while `totalAssets` still reports full backing (no cap on `invest`); `recall` reverts once Aera is short; the tail holder needs 6 claims after recognition. WS-G: a run is rational pre-recognition above a loss of 0.044 % of supply at a 50 %/day recognition probability, and irrational after (the quadratic exit curve does repair the peg).
**Likelihood:** Any cUSD holder watching Aera state or the mempool; cost gas. Preconditions: `reserveVault` set and invested (production intent).
**Proof:** `tests/scratch/E/E_P12_FrontRun.t.sol::test_P12_frontRunRecognition_firstExiterWhole_restAbsorbAll` (fails: `100e18 > 70e18`), `tests/scratch/R2/R2_H2_AeraLoss.t.sol`, `tests/scratch/R1/M4_RecognitionLag.t.sol`, `models/run_dynamics.py`.
**Recommendation:** Record `invested` in `invest`/`recall` and treat `invested − reserveVault-reported value` as provisional bad debt in `unlockedSupply` and `_convertToAssets`; for the credit leg, apply `unrecoverableDebt()` of every market as provisional `badDebt` in the same views. If Aera cannot be valued on-chain, at minimum freeze instant redemptions while `invested > 0` and `recall` reverts. Cap `invest` at `balance − redemptionQueue − remaining`.
**Invariant broken:** the plan's stated un-writable invariant (`totalAssets` vs on hand plus Aera). Single promise: a depositor loses while the system reports itself covered.

#### R3-M4 — Anyone can flood a controller with dust redemption requests; the standard ERC-4626/7540 claim path then costs more than a block (B-1; verified Medium, low end)
**Location:** `contracts/ERC7540/ERC7540AsyncRedeem.sol:L72-L91` (`requestRedeem` accepts any `_controller`), `L94-L108` (`transferRequest` needs no consent from `_to`), `L226-L242` (`maxRedeem`), `L372-L406` (`_claimFifo`, O(n²) sort, `unlockedSupply()` per id), `L337-L356`.
**Impact:** 3-arg `redeem`/`withdraw` exceed 30 M gas at n ≈ 300 (2-tranche senior: 31.16 M), 250 (4 tranches), 350 (cUSD); `maxRedeem` at n ≈ 930. Attacker cost 172 k gas per id (121 k if not reverse-ordered). Verifier's corrections: the victim can shed 300 gifts in one tx via `setOperator` plus a batching contract (15.46 M gas, 29 % of the attacker's 51.78 M), so an EOA or upgradeable victim recovers at a 2.3–3.3:1 cost ratio in its favour; the depositor role is irrelevant because tranche and underwriter share transfers are ungated (a stranger planted 1,000 requests from 1,000 wei of transferred shares). What carries the Medium: a contract integrator written to ERC-4626/7540 only (no `transferRequest`, `setOperator` or 4-arg selector in its bytecode) has no escape and its queued shares are frozen until it upgrades. 4-arg claims stay at 96 k, so the Underwriter and Wrapper are immune. Cost at n = 600 is ~70 % sort, ~30 % oracle walk, so both fixes are needed. No fund loss.
**Proof:** `tests/scratch/B/B_P2_RequestFlood.t.sol` (gas table in `findings/B.md`); verifier's `tests/scratch/verify/B-1/V_B1_RequestFlood.t.sol` (10 pass; n = 300 → 31,164,493 reproduced to the wei).
**Recommendation:** Hoist `unlockedSupply()` out of the per-id loop; require `isOperator(_to, msg.sender)` (or a pull-accept) to become someone's controller; keep `controllerRequests` sorted on insert.

#### R3-M5 — Staker yield is unbounded above the borrow rate whenever `staked < creditBackedSupply`: a borrower that parks its loan opted-in is paid more liquidity premium than it owes (LEAD P8 / G-1; verified Medium)
**Location:** `contracts/utils/PremiumVesting.sol:L114-L123`, `L200-L218`; `contracts/cap/Stablecoin.sol:L83-L86`, `L309-L314`.
**Impact:** On-chain (one borrower, one lender, 50 % utilization, one year): the borrower claimed 42,319.79 of an 84,639.57 liquidity pot, cutting its effective premium from 324,706 to 282,386 (−13 %); the lender's yield is diluted one-for-one. Model (`rate_sweep.py` §5): net cost of credit is negative whenever `staked/S < u/(1 + uw/r)` (26.7 % at u 0.8, harness rates); a $5M loan parked opted-in nets +$257 k/yr with the attacker's only exposure being the idle borrowed cUSD. The deploy seeds 1 cUSD into the Wrapper, so `staked/S` starts near zero.
Verifier's on-chain run (three markets, three borrowers, monthly `chargePremium` and claims, full repay from holdings; `tests/scratch/verify/G-1/G1_Verify.t.sol`, 6 pass): at S 100M / C 80M / W 20M opted-in / D 5M / uw 20 %, the borrower claims 2.289M against 1.852M of own debt growth: **+$437 k net, +$418 k after repaying in full, with zero capital**. At launch (only the 1 cUSD Wrapper seed opted in) a **$1M** loan captures $10.55M against $365 k of cost. Above the threshold (W 40M, uw 20 %) it is −$683 k, so the carry flips once stakers arrive; at uw 5 % the threshold is φ* ≈ 50 %. The excess is a transfer from stakers (lender yield 51.6 % → 45.8 %, never below `r(u)`) plus a small real cost pushed onto other borrowers through higher utilization; a capital staker with no role earns 36.9 % in the same state, so the borrower's special ability is scaling to the credit line with no capital. Note `r = 0` until GOVERNOR sets liquidity slopes (`script/` never does).
**Proof:** `tests/scratch/LEAD/Expected.t.sol::Expected_P8` (fails: `42319786527986081874639 != 0`), `tests/scratch/verify/G-1/G1_Verify.t.sol`, `models/rate_sweep.py` §5.
**Recommendation:** Cap the per-share vest at the borrow rate `r(u)` (pro-rata over `totalSupply`, or an explicit cap). Vesting over `totalSupply − creditBackedSupply` is not enough: staker yield would still be `r·u/(1−u)`, above `r + uw` for u ≳ 0.75 at uw 20 % (0.50 at uw 0). Note that with no eligible tranche the underwriter leg also lands in the cUSD pot (`BaseMarket.sol:L466-L474`).

#### R3-M6 — stcUSD is opted out of premium after any migration that omits `optIn()`; the failure is silent (U-3; verified Medium, merged with R3-H1 for the fix)
**Location:** `contracts/cap/Wrapper.sol:L46` (only `optIn()` call site, inside `initialize`), `contracts/utils/PremiumVesting.sol:L114-L123`.
**Impact / Proof / Recommendation:** see the merged note under R3-H1; `tests/scratch/U/U_LiveUpgrade.t.sol` (stcUSD table), verifier's `tests/scratch/verify/U-3/U3_Verify.t.sol` (6 pass). Fix: `optIn()` inside the Wrapper's `reinitializer(2)`, and a fork test asserting `optedIn(stcUSD)`.

#### Carried Mediums still open
- **M-2** EMA park before a fixed draw (WS-R `R1/M2_EmaManipulation.t.sol`, WS-G `ema_manipulation.py`): flash deposits are now inert, but $100M held one averaging period cuts a $10M/30-day premium from $127,024 to $70,752 (685 bp) for $591 of carry; the break-even parked amount is $0.1M at every permitted averaging period.
- **M-3** JIT premium capture (`R1/M3_JitPremium.t.sol`): 19.7 % of a 30-day fixed premium for 6 hours of exposure; 43 % at 24 h floating; 50 % on `report`; 100 % instant exit.

### Low

New in round 3 (full text in the workstream files):
- **A-1** Underwriter index is a single-checkpoint cubic; under-accrual grows without bound in time since the last `updateUnderwriterRate` (1.9 % after 1 y at a 100 % rate, 14 % at 2 y, 73 % at 5 y; 0.1 %/6.3 % at the 20 % default). Only the market owner can checkpoint it and has no incentive to.
- **B-2** `recognizeBadDebtInReserve` bounds `badDebt` by `totalSupply` only; an over-recognition followed by a permissionless repay drives `totalSupply < badDebt` and every conversion panics until someone mints (I35).
- **B-3** On the Stablecoin, `claim` clamps to `balanceOf(this)` which is escrow plus pot; floor-asymmetric attribution pays up to 1 wei from the redemption escrow (I34 broken by 1 wei; shrunk 16-step sequence).
- **B-4** `Vault.deposit` credits the nominal amount; a fee-on-transfer collateral makes that id insolvent and the first full `slash` reverts the liquidation (I12).
- **C-3** A killed tranche holding dust still takes its full premium weight (0.5-token dead senior out-earns a 1,000-token live junior 19:1) (I39 holds, reported).
- **C-4** `removeTranche` strands all later premium on the remaining position until re-added.
- **C-5** Opt-in is forfeiture by default; a senior with nobody opted in silently redirects 95 % of underwriter premium to cUSD stakers.
- **D-2** For `lt·(1+bonus) > 1e27` GUARDIAN can write off a healthy market while `liquidate` reverts `Healthy()` (band exists above lt 0.9804 at the deploy bonus; loss ≤ 1.96 % of collateral; I38). Verified Low (protocol-trusted misconfiguration). Fix: `_writeOff` requires `healthiness() < 1e27`; enforce the bound in `setLt`/`setLiquidationBonus`/`Registry.initialize`.
- **D-3** An expired, unpaid fixed loan on a healthy market is not liquidatable; the keeper path (`extendAdmin` arrears) takes 186–992 days to make it so and never fully clears (health-targeted `maxLiquidatable`). Verified Low: GUARDIAN `setBuffer(0)`+`setLt(1)` is a blunt but working remedy; the recommended fix is a loan-scoped maturity trigger.
- **D-4** Permissionless premium accrual on an insolvent market grows the eventual write-off by ~0.077 % of debt per day of GUARDIAN delay (WS-G: ~$39 k/day on $50M with $20M unrecoverable; +82 % bad debt at a year), paid to residual-capital tranche stakers and the cUSD pot.
- **D-6** Single permissioned LIQUIDATOR, no fallback; at −1 %/day from health 1.008 the full-recovery boundary passes at ~day 20.
- **E-2** Over-recognition of reserve loss is irreversible; the surplus is stranded forever.
- **E-3** Default deploy puts ADMIN/GOVERNOR/KEEPER/GUARDIAN/LIQUIDATOR on one EOA with no delays; Registry `upgradeToAndCall` is ADMIN by omission and is a full takeover; GOVERNOR `setReserveVault` + KEEPER `invest` drains the reserve with `totalAssets` unchanged.
- **E-4** 17 `restricted` selectors resolve to ADMIN(0) by omission (all `upgradeToAndCall`s; `borrow`/`borrowMore` before `setBorrowerRole`; 7 underwriter selectors before `set*Role`); `RoleTable.t.sol` cannot see it (I40).
- **E-5** `Registry.setDepositorRole` lacks the guards the other two setters have; a tranche or underwriter can be opened to PUBLIC or wired to a protocol role.
- **E-6** `createTranche` uses `hasRole` and discards the execution delay.
- **G-6** GUARDIAN `setBuffer ≥ 0.30` at a full draw locks 100 % of every tranche's shares; `ltv + buffer ≤ lt` is not re-checked.
- **LEAD-3** A market owner can set a funded, locked, third-party junior's premium weight to 0 (accepted by `setTrancheWeights`, `createTranche`, `createFloatingMarket`; no per-tranche floor) while it stays first-loss and cannot exit (`instantRedeem` reverts, async claim 0, `optOut` changes nothing). Verified Low as a sibling of L-21 (`setUnderwriterRate(0)`, IRM:123 "There is no lower bound"): at the harness reference the junior forgoes ~1.0 % APR on capital that a 40 % price drop wipes entirely. Weight 1 wei pays exactly 0 (`rayMul` floors), so a bps floor on both weight and rate is the fix, not a non-zero check. PoC `tests/scratch/verify/LEAD-3/LEAD3_Verify.t.sol` (10 pass).
- **LEAD-1** Credit sizing is a per-market USD notional unbound to collateral composition; after GOVERNOR sizes a line the owner can append a junior in any priced asset, fund it, and withdraw the original collateral (USD coverage unchanged; documented junior-locks-first model; verified Low).
- **U-4** Reserve not on hand after migration (see R3-H1 merged note): par-FIFO redemptions until v1 assets are brought over; v1 loans unrepresentable; wWTGXX wind-down. Verified Low.
- **U-5** cUSD loses `permit`/`nonces`/`DOMAIN_SEPARATOR`. **U-6** config mislabels the timelock. **U-7** upgrade-order dependency; v1 `Pausable` state dropped.

Carried Lows still open: L-5 (= D-2), L-6 (unbounded IRM slopes; base 1e37 accepted and `setLiquiditySlopes(sane)` then reverts), L-10 (= D-4), L-12, L-14, L-15/R2-L2, L-16, L-19, L-20, L-21 (suggest Medium), R2-L3 (half), R2-L4, R2-L5, H-2 residual.

### Informational

Full list in the workstream files. Notable: **A-2** dust-debt markets cannot be liquidated or written off (`_repayWithin` rounds to zero; liveness threshold `⌊idx/RAY⌋ + 2` wei); **A-3** `availableCredit(term)` over-quotes by 1 wei (I32 holds as `totalDebt ≤ creditLimit + 2`); **A-4** half-up `rayMul` where floor/ceil was required in `debtLiquidationThreshold`, `healthiness`, `variableCreditLimit`, `recoverableDebt` (borrower-favourable by ≤ 1 wei); **A-5/A-6** transcendental library confirmation (P5 refuted: index never falls, under-accrues ≤ 1.5e-25 relative per step; `rayExp` shift wraps at x ≥ 115.28e27, unreachable); **A-7** haircut curve inverse holds at 6 and 18 decimals; **A-8** vesting/IRM floors bounded and not farmable; **C-6** injected foreign requests occupy the FIFO watermark ahead of the underwriter; **C-7** no restaking code; **C-8** killed default tranche jams underwriter deposits; **C-9/C-10**; **D-5** waterfall dust ≤ 1 unit of the last delivering tranche (P10 refuted as material); **D-7** oracle: future stamps never stale, `setSource` accepts wrong scale, no min/max clamp, no L2 sequencer feed for monad/tempo/megaeth/katana, unbounded adapter gas lets an invalid primary starve the secondary (1.07e9 gas observed); **E-7..E-11**; **G-7..G-12** (thresholds in §7).

---

## 6. Math analysis (WS-A, `findings/A.md`)

- **Rounding table** (`A.md` §1): every division in scope with direction and beneficiary. Directional rounding is correct where it matters most (`lockedValue` ceil, `_borrowWithin` floor / `_repayWithin` ceil, `Tranche.unlockedSupply` ceil twice, `Stablecoin` `_opposite` on the retained term). Half-up `rayMul` is used in four coverage figures where a floor was required (A-4); the effect is ≤ 1 wei and borrower-favourable.
- **Fixed premium** (§2): `_principalWithin` and `_premium` are consistent to 1 wei; I32 holds as `totalDebt ≤ creditLimit + 2`; the "premium fits inside the limit" claim is true except at `ltv == lt, buffer == 0` where the quoted maximum reverts `Unhealthy` (A-3). Worked example: 500k/30-day at u 0.5, liquidity 6.25 %, underwriter 20 %: premium 10,787.67.
- **Haircut curve** (§3, 6-dec and 18-dec): `_convertToAssets`/`_convertToShares` are inverses within 1 asset-wei across the shortfall domain; no round trip profits (fuzz 20k × 7 properties); split-equivalence holds. The 1e12-share-wei disagreement is the par case only.
- **Floating index** (§4): `_growIndex` split error is one-sided (more splits accrue ≤ 3 wei/step less at 12-s cadence) and integer multipliers are two-sided ±1 wei (I29). `_borrowWithin`/`_repayWithin` shortfall ≤ `⌊idx/RAY⌋ + 1` (I31, fuzz 100k + halmos). `_premium` cannot underflow because both indices are monotone (I41, proof + fuzz 100k on the real IRM).
- **Transcendentals** (§5, bit-exact Python vs `mpmath`, 1e6 points): `rayPowRay(b ≥ RAY, e) ≥ RAY` structurally and `≥ b` for `e ≥ RAY` (I28); max relative error 1.5e-25 per step, one-sided (under-accrual); `rayExp` overflow at x ≥ 115.28e27 needs a growth factor of e^115 per interval, unreachable from `_growIndex` at the 2e27 multiplier cap.
- **MathUtils binomial** (§7): `cubic ≤ (1+x)^n ≤ e^{nx}` always; shortfall 1.9 % at `r·t = 1`, 14 % at 2, 73 % at 5. Harmless for the liquidity index (checkpointed on every stablecoin interaction), material for the underwriter index (A-1).
- **PremiumVesting floors**: 1 wei stranded after 2,000 accruals on a 1e21 pot; splitting never gains (fuzz 20k); a stranded remainder fully vests after 31.4 idle days.
- **halmos** (§6): harness `tests/scratch/A/HalmosMath.t.sol` (12 `check_` functions). Results: see `models/output/halmos_A.log` [pending — the run was relaunched by the lead after the workstream was cut off]. Properties not proved symbolically are labelled fuzz-only in `A.md`.
- **Aave diff** (§8): `WadRayMath` lines 1–105 and `MathUtils` are byte-for-byte Aave v3 except the `rayPow` addition; no rounding direction changed.

---

## 7. Economic analysis (WS-G, `models/`, every number reproducible from `models/output/`)

| Model | Critical threshold |
|---|---|
| `solvency_waterfall.py` | cUSD holders first lose at a collateral drawdown of **49 %** (ltv 0.5) / **28.6 %** (ltv 0.7) with a full draw; junior 5 % weight is wiped at 7 % draw; siloed per-market protection needs ≥ 35 independent markets at 2 % default probability to keep system loss below 1 %. Waterfall dust ≤ price/10^dec per tranche (immaterial). |
| `coverage_dynamics.py` | `healthiness()` leads; the Underwriter book lags each slash by up to the KEEPER report cadence (0/2/8 h at 1/6/24 h) and never reflects price; `backing()` lags until GUARDIAN write-off. Reported coverage is a lagging indicator for underwriter depositors and cUSD holders, leading only for the market view. |
| `liquidation_cascade.py` | Clears bad debt when market impact k < **0.77 / 0.55 / 0 %** per $1M sold at liquidator latency 1 h / 6 h / 24 h (bonus 2 %, lt 0.8); at 24 h latency any impact spirals. Hourly price-fall thresholds for cUSD loss: 19.2 % / 5.45 % / 2.76 %. Fixed cascade: one expiry → market unhealthy from accrual alone after **865 days** (20 % rate); every other borrower's `extend` reverts once unhealthy. |
| `rate_sweep.py` | No protocol take exists. Floating cost is `(1+r)^m − 1` vs fixed `m·r` (+9.18 pts at u 1, m 2). Borrower opt-in capture (R3-M5) is net positive while `staked/S < u/(1+uw/r)` = **26.7 %** at u 0.8. Fixed catch-up on floating notional (R3-M2): $17,123 (15.15 %) on a $10M/30-day draw vs a same-block $50M floating sandwich. Underwriting is unprofitable vs expected slash loss below ~u 0.3 at the harness curve. |
| `run_dynamics.py` | Instant capacity is `(1−u)(1−φ)` of supply (φ = invested fraction). A run is rational before recognition of an Aera loss above **0.044 %** of supply at a 50 %/day recognition probability; irrational after recognition (the curve is monotone; "exit repairs the peg" holds). |
| `param_sensitivity.py` | **12 of 18** governance ranges overlap an unsafe region: lt > 0.9804 (write-off band), slopes ≥ 17,207 %/yr (binomial error), rate > 3.4e11 ray (revert), targetHealth ≥ 2.66 (liquidation over-clears), averaging 5 min (EMA park cost negligible), grace 0, uw 100 % lets an owner-underwriter net positive 81 days after its market turns unhealthy. `Registry.initialize` is now validated. |
| `ema_manipulation.py` | M-2 open: $100M parked one period saves $56,271 on a $10M/30-day premium for $591 carry; break-even $0.1M at every permitted period. |
| `premium_accrual_insolvent.py` | $39 k/day unbacked on $50M with $20M unrecoverable; +5.9 % bad debt at 30 days, +82 % at a year; 71 % to the tranche about to be slashed. |

Note: no mainnet slope, underwriter-rate or ltv values exist in any deploy script; every model states the harness curve it used and sweeps an alternative.

---

## 8. Test suite and mutation testing (`test-suite-assessment.md`)

Qualitative (§1 of the assessment): 574 tests, 0 invariants; assertion-free and implementation-mirroring tests listed with file:line; the harness uses an 18-decimal underlying (mainnet is 6-dec USDC), 3650-day feed staleness (hides every dead-feed path), and a test contract holding all nine roles (27 `restricted` selectors have no negative-caller test). Loosened assertions since round 2 are listed in §1.8 with the commit. §1.9 answers "what would this suite fail to catch": stale-state pricing, third-party-actor sequences (no test has two mutually untrusted operators), 6-decimal rounding, dead-feed liveness, numerical accuracy of the new transcendental math, and anything requiring more than one block of adversarial ordering.

Mutation (§2): Gambit v1.0.6 generated mutants for 12 contracts (ids to 2,677); 752 were run against the full suite in isolated worktrees (17.5 s each including compilation; the test run itself 0.9 s), plus 28 hand-authored semantic changes (29 mutants: flipped rounding, removed checks and clamps, swapped premium legs, linear-for-exponent multiplier, dropped checkpoints). **Score: the stock suite kills 691/781 = 88.5 % raw (91.6 % with the 27 survivors classified equivalent excluded); the ten killing-test files under `tests/mutants/` (32 tests, all passing on HEAD) raise it to 746/781 = 95.5 % (98.9 % adjusted), leaving 8 genuine survivors.** Hand-authored mutants scored 18/29 against the stock suite: `lockedValue` ceil→floor (H01) and dropped junior-capital subtraction (H02), `Tranche.unlockedSupply` ceil→floor (H11), removed on-hand cap in `Stablecoin.unlockedSupply` (H10), dropped `isOperatorRole` check in `setBorrowerRole` (H16), dropped post-extension and post-borrow `Unhealthy` checks (H19, H20), dropped `badDebt ≤ totalSupply` guard (H21), un-checkpointed underwriter rate change (H23), dropped `lt ≤ 1e27` bound (H24), dropped same-window catch-up (H25) — each a money- or coverage-bearing change that passed 574/574; the new tests kill all of them except H20 (reachable only at `ltv == lt − buffer`, A-3). The 55 Gambit survivors the new tests kill concentrate where §1.9 predicted: partial fixed repayments (`-` → `%`), `borrow`/`writeOff` without `_chargePremium`, the Underwriter's `queuedRequest` accounting (10 mutants), the ERC-7540 FIFO and `maxRedeem` clamp (12), `lockedValue`'s junior subtraction, and role guards the harness itself holds. The 8 genuine residual survivors (§2.4 of the assessment) are each one test away: `availableCredit` underflow when the catch-up exceeds the limit (the R3-M2 corollary), `unlockedSupply` underflow in the B-2 state, first-period EMA weight, sub-share `withdraw`, a stale id after `transferRequest`, the 0-tranche market, slash dust, and H20.

The mutation score, not line coverage, is the measure of suite quality; `lcov.info` in the repo is April 2025 v1 data and is not cited.

---

## 9. Invariant suite (`tests/invariants/`, `deep-run.log`)

Handler-based suite ported from round 2 to the ERC-7540 API with a 6-decimal deployer variant (`tests/shared/CapDeployer6.sol`): 23 invariants (I1–I19 carried; I30 master solvency, I33 queue/set consistency, I34 pot separation, I35 supply bound, I37 underwriter book ≥ live, I38 lt·(1+bonus) ≤ 1). Deep run: 1,000 runs × depth 200 = 200,000 calls per invariant, seed `0x5ca1ab1e…cab3`, 859 s wall.

| Result | Invariants |
|---|---|
| PASS at 200k calls | I1, I2, I3, I4, I5, I6, I7, I8, I9, I12, I13, I15, I17, I18, I19, I30, I33, I34, I35, callSummary |
| FAIL | **I38** in 1 call (`setLt(0.99e27)` at the deploy bonus 0.02) — the D-2 finding. **I37** by exactly 1 wei after 7 calls (`uwDeposit → floatBorrow → setLt → floatRepay → floatLiquidate → uwDeposit → trancheDeposit`): each third-party tranche share movement floors on the mover's side and gifts ≤ 1 wei to remaining holders, which is the tolerance WS-C documented (C-2 §I37). Restated as `book + shareOps ≥ live` (one wei of tolerance per share-moving tranche action, `CapHandler.ghost_shareOps`) and rerun alone at 500 runs × depth 200, same seed: **PASS, 100,000 calls, 0 reverts** (`deep-run-I37-500x200.log`, 39 s). |

Supplementary stateful suites: WS-B queue fuzz (48k calls, I26/I33, 0 over-claims), WS-C I37 handlers (~100k calls), WS-A property fuzzes (20k–100k each) and halmos where tractable.

---

## 10. Systemic observations

1. **Round 1's pattern survives: numbers are consumed without a freshness contract at the boundary.** The scale half was fixed in round 2 (C-1). The freshness half is untouched and now has one more instance: `Underwriter.totalAssets` (H-1, both legs), `badDebt` (M-4, R3-M3), the EMA (M-2), `stakedSupply` at funding time (M-3), and new, the underwriter index checkpointed only by owner action (A-1). In every case the NatSpec now describes the lag as intentional. A design that intends a lag must price it (a haircut, a delay on exits, or a permissionless refresh); describing it is not a mitigation.
2. **Round 2's pattern was half fixed: authority moved down a level without its checks.** `setTranches` went back to REGISTRY (R2-M1 fixed). `addTranche` stayed with the curator without a provenance check (R2-H1 open), `setDepositorRole` gained none of the guards its siblings have (E-5), and `createTranche` was added for owners with an inline `hasRole` that ignores delays (E-6). Each `restricted` selector re-homed should carry the check that justified its old home.
3. **New in round 3: every loss-bearing state is refreshed only by a discretionary privileged transaction, and each is front-runnable by the party it would charge.** GUARDIAN `writeOff` and `recognizeBadDebtInReserve` (par exits ahead of them), KEEPER `report` (stale-mark exits and entries), KEEPER `extendAdmin` (expired loans pay nothing until it runs), LIQUIDATOR (single address, no fallback), GOVERNOR `setSource` (dead feed bricks a market). WS-G quantifies the loss as a function of latency for each. The fix pattern is the same everywhere: compute the provisional loss in the view (`unrecoverableDebt`, `invested − reported`, a live mark) and let the redemption or pricing path consume it before the privileged action confirms it.
4. **Global aggregates consumed as if they were per-market or per-class.** `unsmoothedCredit` is global but charged to the next fixed draw (R3-M2); opted-in supply is undifferentiated between reserve-backed and credit-backed cUSD (R3-M5); `fixedCreditLimit` is a per-market notional with no per-asset dimension (LEAD-1). Each lets one actor's position reprice or fund another's.
5. **The code was written for a fresh deployment, and the plan is an upgrade.** No reinitializer, no migration script, no fork test, a config file that mislabels the upgrader, and a reserve that HEAD cannot reach (§5 Highs). This is the item an external firm will open with, because it is discoverable from `config/README.md` without reading a line of Solidity.
6. **The suite pins the mirror.** 18-decimal underlying, ten-year staleness, one address holding every role, zero invariants. The stateful suite under `audit/v3/tests/invariants/` and the killing tests under `tests/mutants/` are candidates for `test/`; `tests/scratch/B/B_P19_Reentrancy.t.sol` and the 6-decimal deployer are the two cheapest additions with the highest coverage gain.

---

## Appendix A — Gas and style (unranked)

Slither (`FOUNDRY_PROFILE=slither slither .`, 99 contracts, 58 detectors, 48 results; JSON in the session scratchpad):

| Detector | Count | Triage |
|---|---|---|
| incorrect-equality | 23 | All are `== 0` / `== block.timestamp` guards on unsigned values (`_writeOff`, `_vested`, `claim`, `_ratio`, `_mark`, `_consumeRequest`, `lockedValue`, `_claimFifo`, `premiumIndices`, `index`, `_chargePremium`, `_liquidate`, `_convertToShares`, `_creditCheck`, `healthiness`, `_claimableShares`, `maxRedeem`, `calculateCompoundedInterest`). Intentional; no finding. |
| unused-return | 17 | `EnumerableSet.add/remove` and `setOperator` booleans ignored (`transferRequest`, `_consumeRequest`, `addTranche`, `removeTranche`); ERC-4626 return values ignored in `Underwriter._allocate/deallocate/finalizeDeallocateAsync` and `Wrapper._deposit/_withdraw`; `latestRoundData` partial destructure. Style; `addTranche` on an already-registered tranche silently re-`optIn`s (harmless). |
| divide-before-multiply | 3 | `ChainlinkAdapter.price` (decimals > 18 path floors then scales — D-7), `MathUtils.calculateCompoundedInterest` ×2 (Aave upstream; A-1 covers the accuracy consequence). |
| reentrancy-no-eth | 3 | `FloatingMarket._chargePremium`/`repay`, `FixedMarket._borrow`: state written after external calls to the stablecoin/IRM; markets are `ReentrancyGuardTransient` and WS-B found no exploitable ordering (P19 refuted). |
| shadowing-state | 1 | `ERC7540AsyncRedeem.STORAGE_LOCATION` shadows `ERC7540Operator.STORAGE_LOCATION` (both `private constant`, different values; rename). |
| uninitialized-local | 1 | `BaseMarket._chargePremium.seniorActive` (bool defaults false; style). |

Workstream appendices (all in `findings/<WS>.md` under "Appendix: gas & style"): 4-arg `redeem/withdraw` accept zero-share claims on any id and still emit; `requestRedeem` with `_controller == address(this)` or `DeadShares.HOLDER` strands shares; `_claimFifo` copies and sorts the whole set per claim (sorted insert would be O(k)); `Stablecoin.fund(0)`/`coverBadDebt(0)` succeed and emit; `BaseMarket.setDepositorRole` wires `deposit/mint` selectors on a market that has neither; `_configureMarketRoles` wires fixed-only selectors on floating markets and `ownerSelectors[3] = extend` is overwritten by the first `setBorrowerRole`; `IncompleteClaim` outer checks are unreachable; `_disableInitializers` repeated in market constructors; `RoleTable.t.sol` header claims 58 selectors and asserts 50; `lockedValue` no-`break` path unreachable; `Underwriter.deallocate(0)` still walks the oracle; `_chargePremium` prices every tranche twice per call; `Tranche.slash` `(total − assets) * 100` overflow bound worth a comment; `CapDeployer._createFixedMarket(string)` does not apply the configured underwriter rate (a harness gotcha that silently produces zero premium).

## Appendix B — Deliverable index

- `audit/v3/00-plan.md` — scope, toolchain, delta, trust model, invariants I1–I40, hypotheses P1–P22, workstreams.
- `audit/v3/findings/{A,B,C,D,E,G,U,LEAD}.md`, `E-roletable.md`, `REGRESSION.md`, `F.md`; `findings/verify/<ID>.md` and `verify/input/`.
- `audit/v3/test-suite-assessment.md`.
- `audit/v3/tests/shared/CapDeployer6.sol`; `tests/invariants/` (+ `deep-run*.log`); `tests/scratch/<WS>/` PoCs with `run.log`s; `tests/scratch/verify/<ID>/`; `tests/mutants/` (+ `mutation.log`).
- `audit/v3/models/*.py`, `models/README.md`, `models/output/`.
