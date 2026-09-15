# Cap v2 — Security & Economic Audit, Round 2 (delta)

**Target:** `cap-network` @ `3dad5ef` ("Refactor premium vesting and natspec"), one commit after the round-1 target `3c45dca` · **Toolchain:** forge 1.6.0-nightly, solc 0.8.36, OpenZeppelin 5.7.0 (unchanged, byte-identical to registry) · **Date:** 2026-09-11 · **Round-1 report:** `audit/cap-v2-audit-report.md`

---

## 1. Executive summary

**Verdict: still not safe to ship.** The refactor fixed the round-1 Critical and four Lows, but **introduced two new Highs** — one of them a regression against the protocol's own documented trust invariant — and left both round-1 Highs and all five round-1 Mediums open.

| | Round 1 (`3c45dca`) | Round 2 (`3dad5ef`) |
|---|---|---|
| Critical | 1 | **0** (C-1 fixed) |
| High | 2 | **4** (H-1, H-2 open; + curator drain, + unrecognised reserve loss) |
| Medium | 5 | **7** (M-1..M-5 open; + owner strips junior, + Wrapper inflation) |
| Low | 21 | 21 → 15 open + 1 replaced + 1 partial, **+ 7 new** (incl. 2 demoted from Medium this round) |

**What changed for the better.** Oracle answers 18 decimals end-to-end and the test deployer now runs the real `Oracle` + `ChainlinkAdapter` (C-1 closed); transient reentrancy guards on every market entry point (L-2 closed); all shared-selector wiring moved into `Registry.initialize` with no selector reaching role 0 by omission (L-7 closed, verified by a 128k-call role fuzz); the EMA is now exponential and path-independent (L-17 closed, 5,000 fuzz runs); `stakedStablecoin` is gone and liquidity premium vests to opted-in cUSD holders instead.

**What blocks launch, in order:**
1. **R2-H1 — Curator drains the Underwriter.** `addTranche` moved from ADMIN to the curator role. It grants ERC-6909 operator over the Underwriter's *entire* vault balance to an unchecked address. The v1 Registry at `3c45dca:426-435` said verbatim this must stay above the curator "so a curator holding it could [not] register a contract of their own and move the balance out"; this commit moved it and deleted the comment. PoC: 100% of TVL on production wiring. Fix: gate `addTranche` on `IRegistry.isTranche` (add it) or move it back to ADMIN.
2. **R2-H2 — An invested reserve loss is never recognised.** New `invest`/`recall` push underlying to an external Aera vault with no cap and no record; `totalAssets`/`maxRedeem` derive from supply, never the reserve, and no role-reachable path books a loss without corrupting `creditBackedSupply`. A shortfall lands 100% on the last redeemers while `maxRedeem` still advertises par. Fix: cap `invest` at a fraction of `unlockedSupply − redemptionQueue` (models: ≤ 0.33 at 1%/day demand), `maxRedeem = min(curve, liquid)`, and a `recognizeReserveLoss` that raises `badDebt` without touching credit.
3. **H-1 and H-2 (round 1) are unchanged** — Underwriter redeems at a stale post-slash mark; queued tranche claims settle past the lock. The lead invariant suite reproduced H-2 on the new code in a 4-call sequence (I17).
4. **M-1..M-5 (round 1) are unchanged**; M-2 and M-3 are numerically smaller under the new curves but the mechanisms and the profit are intact.
5. **New Mediums:** market owner can `setTranches`-drop a funded junior after borrowing (health ≥ 1.0 at `lt` is the only gate; senior loss on default 20% → 80%); `Wrapper` — the "Staked cUSD" product — has no seed and is the sole opted-in holder at launch, so a 1-wei first depositor captures the premium stream and leaves a permanent zero-share trap (fix: seed ≥ 1e18 or add `DeadShares`).

**Fuzzing (the round-2 mandate).** Lead suite: 19 invariants (I1–I19), <!-- DEEP_COUNTS -->. Workstream suites: N1 Stablecoin handler 4 × 16,384 calls + Tranche/Underwriter 2 × 6,144 (opt-in accounting and pot/queue sharing hold exactly); N2 three suites × 128,000 calls (reserve identity holds with `invested` ghost; `maxRedeem` redeemability fails as predicted); N3 role table 4 × 128,000 (no role-0 omission); N4 EMA/`rayPow`/oracle-chain property fuzz 4 × 5,000; R1 queue fuzz reproduces H-2 in 10 calls; R2 EMA path-independence 256. Every Medium+ finding has a failing Foundry test on `3dad5ef`.

**Decisions needed from Matt:** (a) whether the curator is meant to have custody — if not, `addTranche` goes back above the curator today; (b) whether the reserve should be investable at all before a loss-recognition path exists; (c) the `Wrapper` is not in `contracts/deploy/**` — is it in the launch scope, and if so, who seeds it.

---

## 2. Scope, method, reproduction

Delta audit of `git diff 3c45dca..3dad5ef` (74 files, +3,357/−2,889), every changed contract read end to end by the lead and again by the owning workstream. Round-1 methodology unchanged (`audit/00-plan.md`); this round's plan, hypotheses and invariants are `audit/v2/00-plan.md`. Seven parallel workstreams (R1/R2 regression, N1–N4 new surface, G2 models), a lead invariant suite ported and extended, and a fresh disproving agent on every Medium+ (`audit/v2/findings/verify/`, ledger `_LEDGER.md`: 7 verdicts, 5 confirmed, 2 demoted, 0 cut). Baseline on `3dad5ef`: `forge build` exit 0; `forge test` 449/449.

```
FOUNDRY_TEST=audit/v2/tests/scratch/<WS> forge test --match-path 'audit/v2/tests/scratch/<WS>/*' -vv   # WS ∈ R1 R2 N1 N2 N3 N4 verify/<ID>
FOUNDRY_TEST=audit/v2/tests/invariants forge test --match-path 'audit/v2/tests/invariants/*' -vv          # add FOUNDRY_PROFILE=deep
python3 audit/v2/models/<name>.py                                                                          # see audit/v2/models/README.md
```
Round-1 PoCs under `audit/tests/` no longer compile against the new API and were ported, not edited. `contracts/`, `test/`, `foundry.toml` untouched.

---

## 3. Round-1 findings — status on `3dad5ef`

| ID | Round-1 | Status | Evidence |
|---|---|---|---|
| C-1 oracle 8-dec vs 18-dec | Critical | **FIXED** | `R1_C1_OracleDecimals` 5/5: `totalCapital` exact, seize pays `repaid·(1+bonus)` to 1 wei |
| H-1 stale Underwriter mark | High | **OPEN** | `R1_H1_StaleMark` 0/2 — identical numbers to round 1 |
| H-2 queue out-of-order | High | **OPEN** | `R1_H2_*` 0/3; queue fuzz fails in 10 calls; lead I17 fails in 4 |
| M-1 stale feed bricks liquidation | Medium | **OPEN** | `R1_M1` — revert moved from `Oracle` to `Tranche.getPrice`, same effect |
| M-2 EMA manipulation | Medium | **OPEN (reduced)** | 1 h park: 2,439 bps discount, 19× (was 23×); G2: 92% of round-1 saving remains |
| M-3 JIT premium | Medium | **OPEN (reduced)** | take 19.7%/31.6%/43.2% at 6/12/24 h (was 50% at 6 h); 100% instant exit still |
| M-4 recognition lag | Medium | **OPEN** | public `coverBadDebt` only *lowers* `badDebt`; reverts `NoBadDebt` when 0 |
| M-5 loan-id reuse | Medium | **OPEN** | `R1_M5` 95.05% premium avoided on $10M |
| L-2 reentrant liquidate | Low | **FIXED** | guard reverts inner call; Σdebt == credit |
| L-7 selectors at role 0 | Low | **FIXED** | 61 selectors, 0 by omission |
| L-13 epoch restart | Low | **REPLACED** | exponential vest; poke-invariant within 30 wei |
| L-17 EMA regime | Low | **FIXED** | 63% both regimes; 256-run path-independence fuzz |
| L-8 deploy path | Low | **PARTIAL** | Oracle deployed, sink gone; `address(this)` nonce math now also for Registry → broadcast still refused; `script/` still off build path |
| L-15 circuit breaker | Low | **REGRESSED, still Low** | check deleted entirely; verifier found no mainnet feed with a live clamp (10 feeds, block 25,954,033) |
| L-1, L-3, L-4, L-5, L-6, L-9, L-10, L-11, L-12, L-14, L-16, L-18, L-19, L-20, L-21 | Low | **OPEN** | ported PoCs fail as in round 1 (`audit/v2/findings/R2.md`); L-12's new latch still kills an emptied junior (`1000 > 0`) |

---

## 4. New findings (round 2)

### [HIGH] R2-H1 — `Underwriter.addTranche` is now curator-callable and hands blanket ERC-6909 operator rights over the whole vault balance to an unchecked address; the curator drains 100% of depositor funds
**Location:** `contracts/cap/Underwriter.sol:78-87` (`addTranche`: no provenance check, `IVault(vault).setOperator(_tranche, true)`, `IPremiumVesting(_tranche).optIn()`), `contracts/cap/Registry.sol::_configureUnderwriterRoles` (selector in the curator's `operatorSelectors`), `contracts/cap/Vault.sol` (inherited ERC-6909 `transferFrom` honours operator for every id).
**Impact:** Curator deploys a contract with a no-op `optIn()` and a `pull()` that calls `IVault.transferFrom(underwriter, curator, asset, balance)`; `addTranche(fake)`; `pull()`. Every depositor's idle vault balance leaves; the allocated portion follows after `deallocate`. PoC: 1,500e18 idle drained, depositor shares quote 0. Dollars at risk: the Underwriter's TVL.
**Likelihood:** Needs the curator operator role (GOVERNOR-assigned, KEEPER-deployed). Not a privileged-role exclusion: the protocol's own trust model at `3c45dca` (`Registry.sol:426-435`) held this selector above the curator *because* of this exact path; `3dad5ef` moved it and removed the comment. Depositors chose the curator, but the design promised allocation choice, not custody. Revoking the curator's role afterwards does **not** clear the Vault operator flag.
**Proof:** `audit/v2/tests/scratch/N3/` (N3-1) and `audit/v2/tests/scratch/verify/R2-HIGH-CURATOR-DRAIN/Verify_CuratorDrain.t.sol` (3/3, production wiring). Verified CONFIRMED.
**Recommendation:** Add `Registry.isTranche(address)` and require it in `addTranche`; or return `addTranche/removeTranche` to ADMIN as in `3c45dca`. Also `IVault(vault).setOperator(_tranche, false)` on `removeTranche` is already there — but `removeTranche` reverts on a fake that reverts on `previewRedeem/claim`, so ADMIN needs an escape hatch that clears the operator flag without `_report`.
**Invariant broken:** new I25 — every Vault operator granted by an Underwriter is a Registry-deployed tranche.

### [HIGH] R2-H2 — The reserve can be moved to an external Aera vault with no cap and no accounting; a loss there is invisible to every pricing surface and lands entirely on the last redeemers
**Location:** `contracts/cap/Stablecoin.sol:103-118` (`invest`/`recall`: pure pass-throughs, nothing recorded), `:146-180` (`totalAssets = totalSupply − badDebt`, `unlockedSupply`, `_convertToAssets` — all supply-derived), `Registry._configureInfraRoles` (KEEPER, uncapped).
**Impact:** After `invest(x)` and a loss `ℓ` on the Aera leg, `previewRedeem`/`maxRedeem` still quote par; every redemption succeeds at par until the liquid balance is gone, then the rest revert — 100% of `ℓ` on whoever is last, with `maxRedeem` advertising par to them. There is no path to book it: `recognizeBadDebt` is MARKET-only and does `creditBackedSupply −= amount` (underflows at zero credit, corrupts utilization otherwise); `coverBadDebt` reverts `NoBadDebt` while `badDebt == 0`; the one role-reachable sequence that raises `badDebt` (`fundCreditBacked(L)` then `recognizeBadDebt(L)`) also raises `totalSupply` by `L`, leaving payouts overstated by exactly `L`. Model (`reserve_investment.py`): φ = 1, ℓ = 30% → $14M paid at par, $6M stranded.
**Likelihood:** Needs KEEPER to have invested and the external vault to return less (strategy loss, fee, paused/compromised guardian). The protocol chose to expose the reserve; the missing accounting is protocol-owned. Residual doubt: likelihood depends on the real `reserveVault` configuration (tests use `address(0)`; deploy config defaults to `address(0)`).
**Proof:** `audit/v2/tests/scratch/N2/` (`N2LossInvariants` 128,000 calls: gap == Σ aeraLoss exactly, share price stays par; `N2MaxRedeemInvariants` fails in 2 calls) and `verify/R2-HIGH-AERA-LOSS/Verify.t.sol` (11/11). Verified CONFIRMED.
**Recommendation:** Cap `invest` at `(liquid − queuedAssets) × maxInvestBps` (models: ≤ 33% at 1%/day demand for P(revert in 7 d) < 1% with 1-day recall; 0 at ≥ 2%/day); track `invested`; `maxRedeem = min(curve, liquid)` or JIT `recall` inside `_transferOut`; add a GUARDIAN `recognizeReserveLoss(amount)` that raises `badDebt` **without** touching `creditBackedSupply`; ADMIN `setReserveVault` gated on `invested == 0`. Second-order: a recognised reserve loss flows through the existing squared haircut, which is the intended socialisation.
**Invariant broken:** I1 (restated: `liquid + invested ≥ unlockedSupply` holds; `liquid ≥ maxRedeem` does not); new I26 (`redeem(maxRedeem(a))` never reverts).

### [MEDIUM] R2-M1 — Market owner can drop a funded tranche from the waterfall after borrowing; the dropped tranche escapes the lock instantly and the survivors carry the whole default
**Location:** `contracts/cap/market/BaseMarket.sol::_setTranches` (only `Σ weights == 1e27` and `healthiness() ≥ 1e27` at `lt`), `lockedValue` (a tranche not in the array reads 0 — no `break`), `Registry._configureMarketRoles` (`setTranches` now in `ownerSelectors`; was ADMIN).
**Impact:** Owner borrows at `ltv` (health 1.6), then `setTranches` without the junior: health must stay ≥ 1.0, so the owner can strip exactly the 1.6 → 1.0 cushion; the junior's `lockedValue` reads 0 and it exits whole; on a full default the senior's loss rises from 20% to 80% of its capital (PoC). Owner == borrower is permitted by `_createMarket`.
**Likelihood:** Owner operator role only. Fuzz: reachable to exactly health 1.0, never below. Verified CONFIRMED (`verify/R2-MED-OWNER-SETTRANCHES/Verify.t.sol`, 7/7). Corrections from verification: the harm is slash-loop *membership and order*, not the 1.6 → 1.0 cushion — a reorder `[junior, senior]` passes with health unchanged at 1.6 and makes the senior first-loss; at `3c45dca` the owner's worst case via `setLtv` capped the senior's exposure at 54%, now the first-loss layer is voidable entirely; owner == borrower is not required; no GUARDIAN/GOVERNOR/ADMIN action can undo the strip.
**Proof:** `audit/v2/tests/scratch/N3/` (N3-2).
**Recommendation:** While `totalDebt() > 0`, `setTranches` must preserve the set *and the relative order* of every tranche with `totalAssets() > 0` (append-only reweighting via `setTrancheWeights`/`createTranche`); or return `setTranches` to ADMIN as in `3c45dca`. Independently, `lockedValue` for a tranche whose `market()` is this market but which is not listed must return the full `totalDebt/(lt−buffer)` (fail-closed), not 0.
**Invariant broken:** new I27 — while debt is outstanding, the ordered list of tranches with capital is invariant under `setTranches`.

### [MEDIUM] R2-M2 — `Wrapper` has no seed and is the sole opted-in cUSD holder at launch: a 1-wei first depositor captures the premium stream, a later depositor mints 0 shares, and the vault is left in a permanent zero-share trap
**Location:** `contracts/cap/Wrapper.sol` (`totalAssets = balance + claimable`, OZ `_decimalsOffset() == 0`, no `DeadShares`), `contracts/utils/PremiumVesting.sol` (premium accrues to `staked`; while `staked == 0` it freezes and later accrues to the first wei).
**Impact:** Attacker deposits 1 wei; a premium charge lands (or was frozen) and accrues 100% to the Wrapper; victim deposits 400e18 and receives 0 shares (OZ mints 0 silently); attacker redeems ≈ 690e18 including 200e18 of the victim's. After exit `totalSupply == 0` with ~690e18 assets, so every later deposit below that mints 0 shares.
**Likelihood:** Launch window before any direct cUSD `optIn()` of ordinary size (one collapses the attack entirely); nothing in code or deploy enforces one; the `Wrapper` is not in `contracts/deploy/**`. Cost: 1 wei.
**Proof:** `audit/v2/tests/scratch/N1/PoC.t.sol::test_N6b_premiumInflation_zeroCost_firstDepositor`; `verify/R2-MED-WRAPPER-INFLATION/Verify.t.sol` (4/4). Verified CONFIRMED; demotes to Low if the deploy path seeds ≥ 1e18.
**Recommendation:** Seed the Wrapper at deploy (≥ 1e18, unredeemable) or add `DeadShares` as `Tranche` does; revert on `shares == 0`.

### 4.5 New Lows (this round)

| # | Finding | Source |
|---|---|---|
| R2-L1 | `invest` breaks ERC-4626/7540 views: `maxRedeem`/`claimableRedeemRequest` unchanged while liquid balance fell; the first over-liquid claim reverts (settles after `recall` or any fresh deposit). *Demoted from Medium: KEEPER-only, temporary, no loss.* | N2 |
| R2-L2 | Circuit-breaker check deleted (L-15 regressed): a feed clamped at `minAnswer` on a fresh stamp is served with no defence and the secondary is never consulted. *Verifier demoted the proposed Medium: none of 10 mainnet feeds checked publish a live clamp; L2 feeds unverified.* | R2, N4 |
| R2-L3 | `setSource` dry-run only checks `!= 0`; `_read` accepts ≥ 64 bytes — a raw feed as payload serves `roundId` as an 18-dec price; a feed listed twice yields price²/1e18; a 36-dec adapter passes. | N4 |
| R2-L4 | `claim` zeroes `pending`/`debt` before the `balanceOf(this)` clamp; on the Stablecoin a binding clamp would spend queued shares (fuzz: 0 wei shortfall in 28k calls). | N1 |
| R2-L5 | Opt-in economics: a tranche depositor who does not `optIn()` is fully slashable and earns nothing; a 1-wei opted-in holder captures a tranche's full premium share (99.99% of 100e18 in 5.5 d on the frozen-pot path). | N1 |
| R2-L6 | `reserveVault` fixed at init with no setter; deploy config defaults to `address(0)`; a paused/refusing Aera freezes the invested leg until an upgrade. | N2 |
| R2-L7 | L-8 residual: `forge script` refuses `VM.getNonce(address(this))` (now also for the Registry); `_deployInfra` requires the deployer to be the initial ADMIN and then keeps it; `foundry.toml` `script = "scripts"` still hides `script/`. | N3 |

Informational (in workstream files): UUPS inherited on beacon instances is dead surface (`upgradeToAndCall` reverts `UUPSUnauthorizedCallContext`); `ReentrancyGuardTransient` needs EIP-1153 — no `evm_version` pinned and no target chain exercised (recommend a `tstore` probe as the first deploy tx); `Wrapper` not deployed by `DeployInfra`; Registry permanently holds ADMIN + REGISTRY + every market owner role; frozen-pot-then-opt-in is *not* a cliff (curve restarts from the opt-in); pot/queue sharing on the Stablecoin holds exactly (`balanceOf(s) == Σfunded − Σpaid + donated + queue`); cUSD transfer now costs 129,871 gas cold / 22,133 warm.

---

## 5. Invariant and fuzz results

Lead suite `audit/v2/tests/invariants/` (ported handler + I17 queue cap, I18 opt-in supply, I19 vesting bound). <!-- DEEP_TABLE -->

Workstream fuzz (all real counts, default profile unless stated): **N1** `Stablecoin.invariants` 4 invariants × 256 × 64 = 16,384 calls each (0 reverts; I13 restated as `balanceOf(stablecoin) ≥ redemptionQueue() + remaining()` holds; `staked == Σ opted-in` holds); `TrancheUnderwriter.invariants` 2 × 6,144; `rayPow` property 256. **N2** `N2NoLossInvariants` 2 × 128,000 (I1 with invested ghost holds *exactly*); `N2LossInvariants` 128,000 (gap == Σ loss); `N2MaxRedeemInvariants` fails in 2 calls (`deposit → invest`). **N3** role table 4 × 128,000 (I24 holds). **N4** `testFuzz_I22_emaPathIndependent`, `rayPowAccuracy`, `rayPowBoundedAndMonotone`, `threeHopChainError` — 5,000 each (`rayPow` error O(n) ulp, ≤ 1e-18 abs at 10 y; gas 7,208 at n = 3e8). **R1** `R1_H2_Queue.invariants` — H-2 reproduced, shrunk 139 → 10 calls. **R2** `testFuzz_emaPathIndependent` 256.

---

## 6. Economic delta (`audit/v2/models/`, `findings/G2.md`)

Exponential EMA: round-1 M-2 conclusion stands — at u 90%, 1-day period, $100M parked one window still cuts a $10M/30 d premium $127k → $71k for $13.7k (92% of the round-1 saving); break-even D is the grid minimum in every cell. Reserve decay: opt-in fraction does not move `R/S`; but if vested liquidity premium is redeemed the day it vests, `R/S` at 1 y is 6.2% vs 15.5% and the < 5% clock moves 4.5 y → 1.1 y — premium now landing *inside* cUSD shortens the reserve clock. Invested reserve (new): with 1-day recall, φ > 0.75 reverts a 5%/day redemption day; P(revert in 7 d) < 1% needs φ ≤ 0.76 / **0.33** / 0 of `unlockedSupply − queue` at 0.5 / 1 / ≥ 2%/day. JIT under the 12 h vest: 19.7% at 6 h → 49.1% at 48 h, never below time-pro-rata inside a 7 d or 30 d term. Parameter overlap 13/18 → 12/19. `haircut_curve`, `liquidation_cascade`, `rate_sweep`, `solvency_waterfall` diff to 0 lines vs round 1 — the 49.0% depositor-loss threshold, 58% first-liquidation clip, and 2.04% underwriting break-even all still hold.

---

## 7. Systemic observation (round 2)

Round 1's pattern was *numbers consumed without a freshness or scale contract at the boundary*. The refactor fixed the scale case (C-1) and left every freshness case (H-1, H-2, M-4) alone. It then added a second pattern: **authority moved down a level without moving the checks with it.** `addTranche` went to the curator without a provenance check; `setTranches`/`createTranche` went to the market owner without a capital-removal check; `invest` went to the keeper without a cap or a loss path; `coverBadDebt` went public (harmlessly). In three of the four cases the previous commit's own comments explained why the authority sat where it did. The recommendation is procedural as much as technical: when a `restricted` selector is re-homed, the NatSpec that justified its old home is a checklist, not dead text — and `RoleTable.t.sol` should assert *who may not* call, not only who may.

---

## Appendix — gas & style (unranked, additions only)
- `PremiumVesting._update` runs `_accrue` + `rayPow` on every transfer of all three vault tokens; cache `retention` as a constant and skip the pow when `elapsed == 0` (already) or `remainder == 0`.
- `Tranche`/`Underwriter`/`BaseMarket` inherit `UUPSUpgradeable` behind beacons: remove, or document that `upgradeToAndCall` is intentionally unreachable.
- `IStablecoin.coverBadDebt(0)` is an event-spam no-op.
- `script/manage/CheckAccess.s.sol` imports a deleted `contracts/token/Wrapper.sol`; `script/` still does not compile and is still off the build path.
- `foundry.toml`: pin `evm_version` (transient storage) per deployment profile.
- Round-1 appendix items not addressed by this commit still apply.
