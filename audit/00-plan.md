# Cap v2 — Security & Economic Audit

## Context

Cap is a covered-credit protocol for the US dollar: depositors mint cUSD and earn yield,
underwriters post collateral that guarantees loans, and permissioned borrowers draw covered
USD credit. **The single economic promise is that depositors are protected by underwriter
collateral, enforced by contract rather than trust.** Any path where a depositor loses money
while the system reports itself as covered is the top severity class for this audit.

The audit brief describes v1's architecture (Minter, Fractional Reserves, Fee Auction,
Symbiotic/EigenLayer delegation). **That code is gone.** The `cap-network` branch is a
ground-up rewrite: 39 contracts, ~6,400 lines, whose only external imports are OpenZeppelin
and forge-std. `git diff main...HEAD` is +18,095 / −31,800 across 413 files. Restaking is
removed entirely — collateral is now custodied directly by the protocol's own `Vault` as
ERC-6909 and slashed by direct withdrawal. There is no fee auction and no external yield
harvesting.

The rewrite is unaudited, has **zero invariant or fuzz suites** (v1's were deleted), and the
scaffolding for them (`foundry.toml` `[profile.deep.invariant]`, the `test:invariants` npm
script globbing `test/**/*.invariants.t.sol`) points at files that do not exist. Changed code
is where bugs live, and essentially all of this code is changed.

**Scope (confirmed with user):** `contracts/` on `cap-network`, including `contracts/deploy/`.
`script/` is dead v1 code, not on the foundry build path — one line in the report, no audit.
Deliverable includes failing PoCs for every Medium-and-above finding plus a new invariant suite.

## Baseline (established, not assumed)

| Fact | Value |
|---|---|
| Build | `forge build` — **exit 0**, warnings only (all `erc20-unchecked-transfer` in test files) |
| Tests | `forge test --no-match-path 'test/noTest/*'` — **399 passed, 0 failed**, 29 suites, ~482ms |
| Toolchain | forge 1.6.0-nightly, solc 0.8.36, optimizer on, 200 runs |
| Invariant suites | **none** — zero hits for `StdInvariant` / `targetContract` across the repo |
| Fuzz tests | 19 of 399 |
| No test file at all | `Registry.sol`, `BeaconFactory.sol`, `ERC1155Queue.sol`, `ERC7575.sol`, `DeadShares.sol`, all of `contracts/deploy/` |
| Coverage artifacts | `lcov.info` / `coverage/` dated **Apr 2025** — stale, must not be cited |
| **Dependency drift** | `package.json` pins OZ **5.7.0**; `node_modules` has **5.6.1**. Must be pinned before auditing — the ERC-4626 rounding internals are audited code and the version must be known |

## Architecture as derived from the code

Two nested vaults on each side; both sides are ERC-4626 + ERC-7540 async redeem.

**Depositor side.** `Stablecoin` (cUSD) is a plain ERC-4626 over one underlying fixed at init.
`previewDeposit`/`previewMint` mint **at par**, deliberately bypassing the conversion curve.
Underlying sits idle in the contract as the reserve. Borrowers receive `mintCreditBacked` —
cUSD minted against **no reserve at all** — tracked in `creditBackedSupply`. Redemption is
gated on `unlockedSupply() = totalSupply − creditBackedSupply − badDebt`. Bad debt is
socialized through a convex haircut in `_convertToAssets`: whole-supply exit pays the flat
backing ratio, the marginal redeemer is paid that ratio *squared*, and the claimed invariant is
that `k = shortfall/(supply·backing)` is conserved so splitting a redemption is exactly
equivalent.

**Credit side.** Each market owns an ordered array of `Tranche`s with ray weights summing to
exactly `1e27`; index 0 is most senior. A tranche's assets are an ERC-6909 balance in `Vault`.
`Underwriter` is a *curator vault layered on top* of tranches — its `totalAssets` includes a
mark-to-market `totalDebt` refreshed only on `allocate`/`deallocate*`/`report`. Borrowing is
pooled, not attributed per underwriter. `FloatingMarket` tracks one market-level `scaledDebt`
against a compounding index; `FixedMarket` charges the **whole term's premium upfront, folded
into principal**, priced off a time-weighted (EMA) utilization to stop flash-manipulation.

**Yield is minted, not earned.** `BaseMarket._chargePremium` mints fresh credit-backed cUSD to
`stakedStablecoin` and to tranches. Premium does **not** move tranche share price; it flows
through a separate per-share accumulator vesting linearly over 6 hours.

**Loss waterfall.** Liquidation (LIQUIDATOR role only) burns the liquidator's cUSD at par and
slashes tranches **junior-first**, sending collateral to a caller-supplied recipient. Slash
burns no shares — the loss lands as a share-price drop. Residual beyond `recoverableDebt` is
written off (GUARDIAN) into `badDebt` and socialized onto cUSD holders.

**Access.** OZ `AccessManager` with 8 role constants plus dynamic per-instance roles.
`Registry` holds `ADMIN`, so a Registry upgrade is total protocol control (documented at
`Registry.sol:31-39`). Six UUPS singletons; four beacon-proxied per-instance contracts whose
`UpgradeableBeacon`s are `Ownable` by `users.admin` **outside the AccessManager entirely**.
No `__gap` arrays anywhere; ERC-7201 via solc's native `layout at` directive, except
`BaseMarket` / `ERC7540AsyncRedeem` / `ERC7540Operator` which hand-roll slots in assembly.

## System invariants (the backbone)

Written as executable statements; each becomes a handler-based Foundry invariant in
`audit/tests/invariants/`.

**Solvency**
- `I1` — `IERC20(underlying).balanceOf(stablecoin)` scaled to 18dp `>= stablecoin.unlockedSupply()`.
  *If this breaks, the contract reports redeemable supply it cannot pay.*
- `I2` — `totalSupply() >= creditBackedSupply + badDebt`.
- `I3` — `Σ_markets market.totalDebt() == stablecoin.creditBackedSupply()`.
- `I4` — `badDebt` decreases only via `coverBadDebt` or `_onWithdraw`; never underflows.

**Coverage**
- `I5` — for every market: `healthiness() >= 1e27` **or** `unrecoverableDebt() > 0` **or**
  `maxLiquidatable() > 0` and that liquidation is profitable at the current bonus.
- `I6` — `Σ tranche weights == 1e27` after every setter and after `createTranche`.
- `I7` — `lockedValue` is monotonic in seniority: a senior tranche never locks more than a junior one.
- `I8` — `variableCreditLimit() <= debtLiquidationThreshold()` (enforced by `ltv + buffer <= lt`).

**Share price**
- `I9` — `Tranche.previewRedeem(1e18)` never decreases except through `slash`.
- `I10` — the bad-debt curve's split-equivalence: redeeming `S` in one call pays the same
  (±1 wei) as redeeming it in `n` calls, for all `n`, across the whole shortfall domain.
- `I11` — `Stablecoin` deposit→redeem round-trip never pays out more than it took in.

**Conservation**
- `I12` — `∀ asset: IERC20(asset).balanceOf(vault) >= vault.totalSupply(AssetId.toId(asset))`.
- `I13` — queue conservation: `Σ ERC-1155 balances == redeemQueue − settledQueue`, and shares
  held by the vault contract `== redemptionQueue()`.
- `I14` — premium conservation: cUSD credited to tranches + stcUSD `==` premium added to debt.

**Ordering**
- `I15` — FIFO: no request with a higher `queueIndex` becomes claimable before a lower one.
- `I16` — accrual before action: no path mints, burns, borrows, repays, or liquidates against a
  stale index or a stale `Underwriter` mark.

## Attack hypotheses, ranked by expected value

Falsifiable, of the form *actor R with capital C causes outcome O*. Each is assigned to a
workstream and must end as a PoC, a model threshold, or an explicit "could not demonstrate".

| # | Hypothesis | WS |
|---|---|---|
| **H1** | **Yield is minted unbacked.** Every premium accrual mints credit-backed cUSD to lenders, growing `creditBackedSupply` without adding reserve. The reserve ratio therefore decays monotonically with time-at-utilization. Find the utilization × rate × duration at which `unlockedSupply` can no longer service ordinary redemption flow — a solvency clock running by design. | A/G |
| **H2** | **The curator vault marks stale.** `Underwriter.totalAssets` includes `totalDebt`, refreshed only on `allocate`/`deallocate*`/`report`. After a tranche slash and before a KEEPER calls `report`, redemption from the Underwriter is priced at the pre-slash mark — the exiting depositor extracts the loss from those who stay. Redeem is not curator-gated. | C |
| **H3** | **Keeper can roll a defaulted loan forever.** `extendAdmin` (KEEPER) deliberately skips the health check and adds arrears to the term. Each roll charges premium, minting more cUSD to lenders against a borrower who will not repay — `creditBackedSupply` and phantom lender yield both grow while the shortfall compounds, and `writeOff` is a *discretionary* GUARDIAN action. Bad debt can be deferred indefinitely and grown while deferred. | D |
| **H4** | **Oracle fails open at the circuit breaker.** `ChainlinkAdapter._withinBounds` returns `true` on any missing hop (`aggregator()`, `minAnswer()`, `maxAnswer()`), and `Oracle._isStale` treats **future-dated** answers as fresh. Collateral price is the *only* oracle input; overpricing collateral inflates `totalCapital` → `variableCreditLimit` → over-borrow → depositor loss. | E |
| **H5** | **Underwriters exit ahead of the slash.** Borrow capacity uses `ltv × activeCapital` (excludes queued shares) while health uses `lt × totalCapital` (includes them). Queue claims settle out of `unlockedSupply` computed from *current* debt. Test whether an underwriter who queues early claims out whole while the remaining tranche holders absorb the subsequent slash. | C/B |
| **H6** | **Bad-debt curve breaks under rounding.** `_convertToAssets` / `_convertToShares` are claimed exact algebraic inverses with flipped rounding (`_opposite`). Prove or break split-equivalence (I10) and round-trip safety (I11) numerically across the full domain, including near-total shortfall and low-decimal underlyings. | A/G |
| **H7** | **`Vault.deposit` mints before it collects.** ERC-6909 is minted at `Vault.sol:34-36` *before* `safeTransferFrom`, on a permissionless function. A callback token (ERC-777/1363) re-enters holding minted-but-unpaid balance. Related: `createUnderwriter` has **no** oracle-priceability check on its asset, unlike `createTranche`. Fee-on-transfer / rebasing tokens break I12; `IVault.sol:9-13` pushes this onto listing policy rather than code. | F |
| **H8** | **Governance range overlaps the unsafe range.** `base`, `slope0`, `slope1` and `termMultiplierSlope` are **entirely unbounded**; `underwriterRate` has **no lower bound** (zero is legal and documented); `maximumUnderwriterRate` and min/max market multiplier are **init-only with no setter**; `Registry`'s default `lt`/`buffer`/`targetHealth` bypass the validation `BaseMarket`'s own setters enforce. Map permitted range against safe range — every overlap is a finding. | E/G |
| **H9** | **`setAveragingPeriod` is mis-wired.** `ConfigureAccessControl.sol:59` allocates `new bytes4[](3)` and omits `setAveragingPeriod` from the GOVERNOR selector array, so it falls through to AccessManager role 0 = **ADMIN**. The same omission is mirrored in `test/shared/CapDeployer.sol:270-274`, so `RoleTable.t.sol` pins the wrong table and the test suite cannot catch it. Shrinking the averaging period is the lever that re-opens H10. | F |
| **H10** | **EMA manipulation for cheap fixed debt.** Cost to move `averageUtilizationAfterMint` over `averagingPeriod` (banded 5 min – 1 day) versus the discount on a maximum-term fixed loan. `Stablecoin` deposit/redeem is permissionless, at par, with **no fee** — the only cost is capital and time. Compute the break-even and compare to the band. | E/G |
| **H11** | **Liquidation depends on one privileged, solvent actor.** `liquidate` is LIQUIDATOR-only, and the liquidator must hold and burn cUSD at par. If they are offline, undercapitalized, or the bonus is unprofitable, no one else can act — and `unrecoverableDebt` grows. Model the liveness/capital requirement and the bonus × `lt` × `targetHealth` region where liquidation stalls or cascades. | D/G |
| **H12** | **Premium silently redirects to lenders.** `_chargePremium` skips tranches with `stakedSupply()==0` and hands the remainder to the senior tranche — or, if the senior is also inactive, to `stakedStablecoin`. Underwriter premium can be routed wholesale to depositors without the underwriters' knowledge. | C |
| **H13** | **Storage-layout collision.** `BaseMarket` hand-rolls an ERC-7201 slot in assembly while `FixedMarket`/`FloatingMarket` use solc's native `layout at erc7201` directive; `ERC7540AsyncRedeem`/`ERC7540Operator` declare their slots as `uint256` and assign `$.slot :=` in assembly. Verify every hardcoded constant against the real `erc7201` hash and check derived-vs-base namespace overlap. No `__gap` exists anywhere. Beacons are `Ownable` by `users.admin`, outside the AccessManager. | F |
| **H14** | **Tranche `killed` latch is one-way.** `totalSupply > totalAssets × 100` permanently kills a tranche. Can an attacker force the ratio across `KILL_RATIO` cheaply — via a dust deposit at a manipulated price, or by slashing to near-zero — to permanently disable a market's collateral pool? | C |
| **H15** | **First-deposit windfall.** `Tranche.previewDeposit` **ignores `totalAssets()` entirely while `totalSupply == 0`**, so a pre-deposit donation via `IVault.transfer` is a windfall to the first depositor rather than a trap. `DeadShares` (1e3 seed) + OZ virtual shares protect the *ratio*; check whether the donation path can instead inflate `totalCapital` → `variableCreditLimit` in a way the market misprices. | B |

## Plan of work

### Phase 0 — Pin the environment (must precede everything)
Resolve the OZ 5.6.1 / 5.7.0 drift and record which version the audit ran against. Verify OZ is
unmodified (`npm pack` checksum against the registry) before excluding it from scope. Re-record
build and test commands. Write `audit/00-plan.md` from this document.

### Phase 1 — Parallel specialist passes
Seven workstreams, spawned in parallel, each given the invariant list and its hypotheses.
Each returns findings in the brief's §5 schema plus any invariant it believes it broke.

| WS | Focus | Primary files |
|---|---|---|
| **A** | Reserve, peg, bad-debt curve | `Stablecoin.sol`, `Vault.sol` |
| **B** | Async redemption queue, run mechanics, first-depositor | `ERC7540*`, `ERC1155Queue.sol`, `DeadShares.sol` |
| **C** | Coverage, tranches, curator vault, slash waterfall | `Tranche.sol`, `Underwriter.sol`, `BaseMarket.sol`, `PremiumVesting.sol` |
| **D** | Markets, liquidation, write-off, rollover | `FloatingMarket.sol`, `FixedMarket.sol`, `BaseMarket.sol` |
| **E** | Rates, EMA, oracle | `InterestRateModel.sol`, `Oracle.sol`, `ChainlinkAdapter.sol`, `MathUtils.sol`, `WadRayMath.sol` |
| **F** | Access control, upgrades, deploy wiring, code safety | `Registry.sol`, `CapRoles.sol`, `BeaconFactory.sol`, `contracts/deploy/**` |
| **G** | Economic modelling (Python) | `audit/models/` |

### Phase 2 — Proof
- A Foundry test that **fails on current code** for every Medium-and-above finding, in `audit/tests/`.
- Handler-based invariant suites for I1–I16 in `audit/tests/invariants/`, named
  `*.invariants.t.sol` so the repo's existing `test:invariants` script finally resolves.
  Run under `FOUNDRY_PROFILE=deep` (5,000 runs × depth 200); report actual run counts.
- Real pasted output only. A suspected bug that resists proof goes to Informational with what
  was tried and what would settle it.

### Phase 3 — Adversarial verification
One fresh subagent per Critical/High/Medium finding, tasked with **disproving** it. Anything
that does not survive is demoted or cut with a one-line note. Then a cross-finding pass for the
systemic pattern — the recurring assumption or inconsistently-applied check that the individual
bugs point at.

### Phase 4 — Report
`audit/cap-v2-audit-report.md`: 60-second executive summary (ship / don't ship, and what
blocks), scope and method, **trust model as derived from the code** with deviations from the
documented one called out, findings by severity, economic analysis with numeric thresholds,
systemic observations, and a single unranked gas/style appendix.

## Economic models — `audit/models/`

Every model states its assumptions, uses realistic values, and reports the **critical
threshold** (the number at which behaviour changes), not a pass/fail.

| Model | Question it settles | Hyp |
|---|---|---|
| `reserve_decay.py` | At what utilization × rate × duration does minted yield push the reserve ratio below ordinary redemption demand? | H1 |
| `solvency_waterfall.py` | Correlated collateral drawdown through the junior→senior waterfall. **The shock size at which cUSD holders first take a loss**, as a number. | — |
| `haircut_curve.py` | Numerical proof/refutation of split-equivalence and round-trip safety across the full shortfall domain and all underlying decimals. | H6 |
| `liquidation_cascade.py` | Price path → `maxLiquidatable` → slash → `totalCapital` drop → next liquidation. Does it clear or spiral, and at what `liquidationBonus` / `lt` / `targetHealth`? | H11 |
| `rate_sweep.py` | Lender yield vs underwriter premium vs protocol take across utilization. **Find the region where underwriting is unprofitable** — where underwriters rationally withdraw exactly when most needed (note: underwriter rate has no lower bound). | H8 |
| `run_dynamics.py` | FIFO queue vs `unlockedSupply` recovery. Withdrawal fraction that breaks orderly redemption; whether the convex haircut actually removes the first-mover advantage it is designed to remove. | H5 |
| `ema_manipulation.py` | Capital × time to move the EMA vs the discount won on a max-term fixed loan. Break-even against the 5 min – 1 day band. | H10 |
| `param_sensitivity.py` | For every governance-settable parameter: the values at which the system misbehaves vs. what governance is permitted to set. Every overlap is a finding. | H8 |

Coverage-ratio dynamics are folded into `solvency_waterfall.py`, which must additionally report
whether `healthiness()` is a **leading or lagging** indicator of real protection. If it lags,
that is itself a finding.

## Deliverables

```
audit/00-plan.md                    scope, invariants, hypotheses, assignments
audit/cap-v2-audit-report.md        the report
audit/tests/                        failing PoC per Medium+ finding
audit/tests/invariants/*.invariants.t.sol   I1–I16 handler-based suites
audit/models/                       runnable Python + README of assumptions
```

## Verification

1. `forge build` — exit 0 (baseline already established).
2. `forge test --no-match-path 'test/noTest/*'` — 399 pass, unchanged. The audit adds tests; it
   must not modify `contracts/` or existing `test/`.
3. `forge test --match-path 'audit/tests/**'` — every PoC **fails on current code**, with
   pasted output. A PoC that passes is not a finding.
4. `FOUNDRY_PROFILE=deep forge test --match-path 'audit/tests/invariants/*.invariants.t.sol'` —
   report per-invariant pass/fail with actual run and depth counts.
5. `python audit/models/<name>.py` for each model — each prints its critical threshold.
6. Cross-check: every Medium+ finding in the report names either a failing test in
   `audit/tests/` or a model output with a threshold. Anything that names neither is demoted to
   Informational with the reason stated.

## Ground rules carried from the brief

- Assume nothing. NatSpec that says "safe because X" is a hypothesis to test, not evidence —
  and this codebase is unusually comment-heavy with exactly that kind of claim.
- No speculative findings. Medium+ requires an ordered exploit path with attacker capital and
  net profit, or a failing test. Otherwise demote and say why it could not be demonstrated.
- No finding inflation. Gas and style go in one unranked appendix.
- Read the implementation of every in-scope contract end to end at least once.

---

# Phase 0 results — environment pinned (executed)

| Item | Result |
|---|---|
| OZ drift | **Resolved.** `package.json`, `package-lock.json` and `yarn.lock` all pin **5.7.0**; the working tree had a stale **5.6.1** install. Installed 5.7.0 with `npm install @openzeppelin/contracts@5.7.0 @openzeppelin/contracts-upgradeable@5.7.0 --no-save` (no manifest or lockfile was modified). **The audit runs against 5.7.0 — the version CI and a fresh clone resolve.** |
| OZ integrity | **Verified unmodified.** `diff -rq` of both installed packages against the pristine registry tarballs (`npm pack @openzeppelin/contracts@5.7.0`, `@openzeppelin/contracts-upgradeable@5.7.0`) is **empty** — byte-identical. Excluded from scope on evidence, not assumption. |
| Build @ 5.7.0 | `forge build` — exit 0, no errors. |
| Tests @ 5.7.0 | `forge test --no-match-path 'test/noTest/*'` — **399 passed, 0 failed, 0 skipped**, 29 suites. |
| Third-party in `contracts/` | Only `@openzeppelin/*` and one `forge-std/Vm.sol` import (`contracts/deploy/service/DeployInfra.sol:15`, cheatcodes in a contract that ships in the production build — noted for WS-F). |

**Anyone reproducing this audit must install OZ 5.7.0 first**; a stale 5.6.1 tree changes the
ERC-4626 rounding internals underneath `Tranche` and `Stablecoin`.

---

# Phase 1–4 outcome (executed)

| Workstream | Delivered | Med+ claimed → survived verification |
|---|---|---|
| A reserve/peg | `findings/A.md`, `tests/scratch/A/` | 0 → 0 (2 Low; H1/H6 refuted as defects) |
| B async queue | `findings/B.md`, `tests/scratch/B/` | 1 High → **1 High** (H-2) |
| C coverage/tranches | `findings/C.md`, `tests/scratch/C/` | 1 High + 2 Med → **1 High (H-1), 2 Med (M-1, M-3)** |
| D markets/liquidation | `findings/D.md`, `tests/scratch/D/` | 3 Med → **1 Med (M-5)**, 2 demoted to Low (L-9, L-10) |
| E rates/oracle | `findings/E.md`, `tests/scratch/E/` | 1 Crit + 1 Med → **1 Crit (C-1), 1 Med (M-2)** |
| F access/upgrades | `findings/F.md`, `tests/scratch/F/` | 0 → 0 (4 Low; H9 confirmed, H13 refuted) |
| G economic models | `findings/G.md`, `models/` | 2 Med → **1 Med (M-4)**, 1 duplicate of M-2 |
| Lead | `findings/LEAD.md`, `tests/scratch/LEAD/`, `tests/invariants/` | C-1 found independently; 14/14 invariants at 5,000 × 1M calls |

Hypothesis outcomes: H1 slow clock (Info) · H2 **High** · H3 Low (demoted) · H4 Low ×2 · H5 by design (Info) · H6 refuted · H7 Low · H8 Low ×3 · H9 Low · H10 **Medium** · H11 Low · H12 Low · H13 refuted · H14 Low · H15 refuted (windfall, not trap). Unplanned: C-1 (lead), H-2 (WS-B), M-3, M-4, M-5.

Verification ledger: `findings/verify/_LEDGER.md`. Report: `cap-v2-audit-report.md`.
