# Cap v2 — Audit Round 2 (delta) — plan

**Target:** `cap-network` @ `3dad5ef` ("Refactor premium vesting and natspec"), one commit after the round-1 target `3c45dca`. 74 files, +3,357/−2,889. Baseline on this commit: `forge build` exit 0; `forge test` **449 pass / 0 fail** (was 399). OZ 5.7.0 unchanged and still byte-identical to the registry. Round-1 report: `audit/cap-v2-audit-report.md`.

**Mandate for this round:** (1) re-verify every round-1 finding against the new code — fixed, partially fixed, or open — with a ported, running PoC as evidence; (2) audit the new and rewritten surface as if it were new code; (3) **fuzz testing is a first-class deliverable**: every workstream ships stateful or property fuzz suites, the lead ports and extends the invariant suite to the new API and re-runs it under `[profile.deep]`.

## 1. What changed (from `git diff 3c45dca..3dad5ef`, read in full by the lead)

| Area | Change | Round-1 finding it targets |
|---|---|---|
| Oracle | `Oracle.DECIMALS` 8 → **18**; `ChainlinkAdapter` is now a `library` normalising to 18; per-asset `Sources[]` chain, each hop `{primary, secondary}` with own staleness; `setSource` dry-runs the chain; `price()` returns only the answer; **circuit-breaker (`minAnswer/maxAnswer`) check deleted**, `IncompleteRound` check deleted (zero stamp now falls to staleness → secondary) | C-1 (fix), L-15 (deleted, not fixed), L-16 (unchanged) |
| Deploy/tests | `DeployInfra` deploys the real `Oracle` + adapter; `MockOracle` deleted; `CapDeployer` uses the real `Oracle` with 8-dec `MockAggregator`s; `Deployment.t.sol`, `LiquidationReentrancy.t.sol`, `Wrapper.t.sol` added; `stakedStablecoin` removed everywhere | C-1, L-8 |
| Roles | All shared-selector wiring moved into `Registry.initialize → _configureInfraRoles()` (Registry must hold ADMIN *before* init; `DeployInfra` precomputes its address); `setAveragingPeriod` and `Oracle.setSource` → GOVERNOR; `MINTER` role removed (`MARKET = 4`, `REGISTRY = 5`, `LIQUIDATOR = 6`); `createMarket` → `createFloatingMarket`; **`createTranche` and `setTranches` → market OWNER** (was ADMIN); **`Underwriter.addTranche/removeTranche` → curator operator role** (was ADMIN); `coverBadDebt` → **public**; `invest/recall` → KEEPER | L-7 (fix), new surface |
| Reentrancy | `BaseMarket` inherits `ReentrancyGuardTransient`; `nonReentrant` on every market entry point incl. `chargePremium`, `repay` | L-2 (fix) |
| PremiumVesting | Library → **abstract contract** inherited by `Stablecoin`, `Tranche`, `Underwriter`; hand-rolled ERC-7201 slot; **opt-in model** (`optIn()/optOut()`, `staked = Σ opted-in balances`); exponential vest `1 − r^t` with **fixed 12 h** time constant (`setVestingPeriod` gone); zero staked supply freezes; `_update` accrues + checkpoints on every transfer | M-3 (partial?), L-13 (replaced), L-14 (unchanged) |
| Stablecoin | Now a `PremiumVesting` over itself (`stablecoin() == address(this)`); liquidity premium is `fundCreditBacked` → minted to the Stablecoin and vested to **opted-in cUSD holders**; public `fund()` (donation); **`invest(amount)`/`recall(amount)` move underlying to/from an external Aera `reserveVault`** fixed at init (no setter); `coverBadDebt` public | replaces stcUSD; new surface |
| Wrapper (new) | ERC-4626 + Permit over cUSD; opts in at init; `totalAssets = balance + claimable(this)`; claims on every deposit/withdraw | new (this is the stcUSD-equivalent) |
| IRM | EMA weight now `1 − retentionPerSecond^elapsed` via new `WadRayMath.rayPow` (path-independent); `retentionPerSecond = 1e27 − 1e27/period` | L-17 (fix) |
| Tranche | `slash` kill latch now `totalSupply > (total − assets)·100` evaluated **before** the withdrawal; `notifyPremium/claim/setVestingPeriod` gone (via base); `fund(premium)` MARKET-only; **UUPS inherited although deployed behind a beacon** | L-12 (still fires on a dust-holding emptied junior), L-13 |
| Underwriter | `ERC1155Holder`; `addTranche` also `optIn()`s on the tranche; `removeTranche` reports first; `_report` claims tranche premium and funds own pot; `lastReported`; UUPS inherited | H-1 **unchanged** (no re-mark on redeem) |
| Markets | `_chargePremium` routes liquidity premium to the Stablecoin pot; no other logic change | H-2, M-5, L-1, L-3, L-9, L-10 **unchanged** |
| ERC7540AsyncRedeem | `ERC165Upgradeable` → `ERC165`; no arithmetic change | H-2 **unchanged** |

Not changed: `Vault.sol` (L-18 open), `Registry.initialize` still stores `lt/buffer/targetHealth` unvalidated (L-4 open), `FixedMarket` id bounds (M-5 open), `FloatingMarket._premium` rounding (L-1 open), `FloatingMarket.borrow` health assert (L-3 open), multiplier-on-index (L-9 open).

## 2. Round-1 findings — status hypotheses to verify (WS-R1, WS-R2)

| ID | Round-1 | Hypothesis on `3dad5ef` | Evidence required |
|---|---|---|---|
| C-1 | Critical | **Fixed** — 18-dec end to end; real oracle in tests | Port `E1_OracleDecimals`; assert `totalCapital` = 18-dec USD, seize path pays `1+bonus` exactly |
| H-1 | High | **Open** — no `_mark` on `redeem/withdraw`; `report` KEEPER-only | Port `C1_StaleMark`; must still fail |
| H-2 | High | **Open** — `claimableRedeemRequest` unchanged | Port `B1_OutOfOrderSettlement`; must still fail |
| M-1 | Medium | **Open** — `totalCapital` still sums reverting `getPrice()`; note `Oracle.price` now returns 0 (not revert) for an unpriced asset but `Tranche.getPrice` reverts on 0 | Port `C3` |
| M-2 | Medium | **Open** — exponential weight does not touch supply dilution | Port `E2`; recompute numbers with `rayPow` weighting |
| M-3 | Medium | **Partially changed** — 12 h exponential instead of 6 h linear; JIT still credited at arrival; opt-in adds a step | Port `C2`; measure the take at 6 h/12 h/24 h |
| M-4 | Medium | **Open** — `coverBadDebt` public does not recognise anything | Re-run `Verify_RecognitionLag` |
| M-5 | Medium | **Open** | Port `D9` |
| L-1 | Low | Open | Port `Reserve.t.sol::test_driftBricksFullRepayAndWriteOff` |
| L-2 | Low | **Fixed** (transient guard) — verify the repo's `LiquidationReentrancy.t.sol` covers the recipient-hook path and that guards are on *every* market entry point; also check `Tranche`/`Underwriter`/`Stablecoin` which have **no** guard | Port `F3_ReentrantLiquidate` (must pass now) |
| L-3 | Low | Open | Port `D4` |
| L-4 | Low | Open | Port `F2`/`D5` |
| L-5 | Low | Open (`setLt` unchanged) | model |
| L-6 | Low | Open (slopes unbounded) | Port `E4` |
| L-7 | Low | **Fixed** — recompute the full production role table via `DeployInfra` + `Registry.initialize`; list any selector reaching role 0 by omission | new role-table harness |
| L-8 | Low | **Partially** — Oracle deployed, `stakedStablecoin` gone; `address(this)` nonce math *still* used (and now for Registry too) so broadcast likely still fails; `script/` still off the build path | re-run broadcast simulation |
| L-9 | Low | Open | Port `D1` |
| L-10 | Low | Open | Port `D2` |
| L-11 | Low | Open (`_chargePremium` gates on `stakedSupply`, now = opted-in) | Port `D2` sub-test |
| L-12 | Low | Open — new latch still `1000 > (dust−dust)·100` | Port `C4` |
| L-13 | Low | **Replaced** — no epoch restart; exponential vest is now the design | confirm `chargePremium` spam no longer changes release |
| L-14 | Low | Open — queued shares leave `staked` | Port `C5` |
| L-15 | Low | **Regressed** — bounds check deleted; a clamped feed is now accepted with no defence at all | new PoC |
| L-16 | Low | Open (`_isStale` unchanged) | Port `E3::H4b` |
| L-17 | Low | **Fixed** — verify `rayPow` path-independence by fuzz (n accruals over P vs one) | new fuzz |
| L-18 | Low | Open (`Vault.deposit` order unchanged) | Port `VaultCallback` |
| L-19/20/21 | Low | Open (economics unchanged) | model |

## 3. New attack hypotheses (from the lead's read of the new code)

| # | Hypothesis | WS |
|---|---|---|
| **N1** | **Curator drains the Underwriter.** `addTranche` is now curator-callable and grants `IVault.setOperator(_tranche, true)` to an *unchecked* address, then calls `optIn()` on it. A curator registers a contract of their own and `transferFrom`s every depositor's vault balance (every asset id) out. The v1 Registry comment held this above the curator for exactly this reason. Expected: **High** (permissioned but semi-trusted role, direct theft of user funds). | N3 |
| **N2** | **Invested reserve breaks I1 and lies to ERC-4626.** After KEEPER `invest(x)`, `unlockedSupply()`/`maxRedeem` are unchanged but `balanceOf(stablecoin)` fell by `x`; instant and queued redemptions revert on `safeTransfer`. `recall` is discretionary; an Aera loss is never recognised (only `badDebt` haircuts). Quantify: (a) DoS window, (b) who eats an Aera loss (last redeemers), (c) can `invest` be called with `reserveVault == 0` (tests deploy with `address(0)`). | N2 |
| **N3** | **Premium pot and redemption queue share one balance.** `Stablecoin` holds its own premium (`fundCreditBacked` → `address(this)`) in the same `balanceOf(address(this))` as queued redemption shares. `claim` clamps to that balance. Can a claim pay out of queued shares (or a queued claim burn the pot)? Does `_burn(address(this), shares)` in the queued path ever exceed the queue? I13 must be restated. | N1 |
| **N4** | **Opt-in accounting.** `staked` must equal Σ opted-in balances at all times across mint/burn/transfer/requestRedeem/claim/optIn/optOut/slash. Any drift → over/under-attribution or an underflow in `_checkpoint` (`_owed(perShare, bal) − debt`). Fuzz it on all three vaults. Also: an account that opts in, transfers to itself, or receives from `address(this)` on claim. | N1 |
| **N5** | **Vesting conservation under exponential weight.** `Σ claimed + Σ claimable + remaining ≤ Σ funded` (+ dust), `remaining` never negative, `rayPow` never overflows/underflows to a wrong weight for elapsed up to years; a zero-staked freeze then opt-in cannot sweep the frozen pot (the round-1 "cliff" concern). | N1 |
| **N6** | **Wrapper share price.** `totalAssets` includes projected `claimable`; deposits claim first. Check: first-depositor inflation (no dead shares), `claimable` overstated vs what `claim` pays (clamp), share price monotone, and whether `Wrapper` deposits/withdrawals of cUSD trigger Stablecoin `_update` checkpoint correctly so Wrapper's own entitlement is not lost. | N1 |
| **N7** | **Owner-controlled waterfall.** Market OWNER can now `setTranches` (any subset/order of its own tranches) and `createTranche`. Removing a tranche from the array sets its holders' `lockedValue` to 0 (they exit freely) while `healthiness ≥ 1` is the only check (at `lt`, not `ltv`). Owner == borrower is permitted. Can the owner strip coverage to health 1.0 then default? | N3 |
| **N8** | **Oracle regressions.** Bounds check deleted (LUNA clamp accepted); `price()` returns 0 for an unconfigured asset; `_read` still decodes any ≥64-byte return; future stamps still fresh; `setSource` dry-run passes a price that is wrong by scale (e.g. a feed with 18 decimals scaled to 36). `IChainlink` changed — check `decimals()` failure path. | N4 |
| **N9** | **Guard coverage.** `nonReentrant` is on markets only. `Tranche.slash` (called inside the guarded market) → `Vault.withdraw` → token hook → can the hook re-enter `Tranche.redeem`/`requestRedeem`/`optOut`/`claim` or `Stablecoin.*` mid-slash (read-only or state)? The kill latch now runs before the withdrawal — was that sufficient? | N4 |
| **N10** | **UUPS on beacon instances.** `Tranche`/`Underwriter`/markets inherit `UUPSUpgradeable` but are `BeaconProxy` instances: `upgradeToAndCall` must revert `UUPSUnauthorizedCallContext`. Confirm; and confirm the implementation contracts themselves (not proxies) cannot be initialised/upgraded. Registry must hold ADMIN before `initialize` — what if it doesn't (revert = fine) or if `initialize` is front-run? | N3 |
| **N11** | **`ReentrancyGuardTransient` needs EIP-1153.** `foundry.toml` sets no `evm_version`; the RPC list includes Monad/Tempo/MegaETH/Katana. On a chain without TSTORE every guarded function reverts. Deployment-target Info/Low. | N3 |
| **N12** | **Every cUSD transfer now runs `_accrue` + `rayPow`.** Gas per transfer and any path where `_update` can revert and brick transfers (e.g. `staked -= amount` underflow if `staked` drifts). | N1 |

## 4. Invariants (round-2 suite, `audit/v2/tests/invariants/`)

Carry I1–I16 (I1 now stated as **`balanceOf(stablecoin) + invested ≥ unlockedSupply`** with `invested` a ghost, and separately **`balanceOf(stablecoin) ≥ unlockedSupply` whenever `invested == 0`**; I13 restated as `balanceOf(vault) ≥ redemptionQueue` for the Stablecoin and `==` for tranches/underwriters) and add:

- **I17** `Σ_open claimableRedeemRequest ≤ unlockedSupply()` on every tranche and underwriter (the H-2 statement).
- **I18** `stakedSupply() == Σ_{opted-in} balanceOf` on every `PremiumVesting` vault.
- **I19** Premium conservation per vault: `Σ claimed + Σ claimable + remaining() ≤ Σ funded + dust`.
- **I20** `remaining()` never underflows; `vested() ≤ remainder`.
- **I21** Wrapper: `previewRedeem(1e18)` non-decreasing across every action except a cUSD haircut.
- **I22** EMA path-independence: `averageSupplies()` after `P` seconds is the same whether accrued once or every `k` seconds (property fuzz, not stateful).
- **I23** `Underwriter.totalDebt == Σ previewRedeem(balanceOf(t) + queuedShares[t])` at every deposit/redeem (the H-1 statement) — expected to FAIL; kept to document.
- **I24** Every `restricted` selector on every deployed instance resolves to a role named in `Registry._configure*` — never role 0 by omission.

## 5. Workstreams

| WS | Focus | Deliverable |
|---|---|---|
| **R1** | Regression of C-1, H-1, H-2, M-1..M-5 | `findings/R1.md`, ported PoCs under `tests/scratch/R1/`, status table |
| **R2** | Regression of L-1..L-21 | `findings/R2.md`, ported PoCs under `tests/scratch/R2/`, status table |
| **N1** | `PremiumVesting` base (opt-in, exponential vest), `Stablecoin` self-vesting + pot/queue sharing, `Wrapper` | findings + **stateful fuzz** for I18/I19/I20/I21, N3–N6, N12 |
| **N2** | `Stablecoin.invest/recall` + Aera, `coverBadDebt` public, `fund` public, reserve identity | findings + **stateful fuzz** for I1 (with invested ghost), N2 |
| **N3** | Registry/roles/upgrades/deploy: curator `addTranche` (N1), owner `setTranches`/`createTranche` (N7), UUPS-on-beacon (N10), role table (I24), broadcast (L-8), EIP-1153 (N11) | findings + role-table harness |
| **N4** | Oracle rewrite (N8), EMA `rayPow` (I22, L-17), kill latch (L-12), guard coverage (N9) | findings + **property fuzz** for `rayPow`, EMA, oracle scale, kill latch |
| **G2** | Model delta: liquidity premium now vests to cUSD holders (changes `reserve_decay`), exponential EMA (changes `ema_manipulation`), invested reserve (new `reserve_investment.py`), 12 h exponential vesting (changes JIT numbers) | `audit/v2/models/`, `findings/G2.md` |
| **Lead** | Port + extend invariant suite (I1–I24), deep run, Phase-3 verification of every Medium+, report `audit/v2/cap-v2-audit-report-r2.md` | |

Ground rules are unchanged (`findings/_SCHEMA.md`): NatSpec is a hypothesis; Medium+ needs a failing test; no inflation; fuzz counts must be real.

---

# Outcome (executed 2026-09-11)

Round-1 status: C-1 FIXED · H-1, H-2 OPEN · M-1..M-5 OPEN (M-2, M-3 reduced) · Lows: 3 fixed (L-2, L-7, L-17), 1 replaced (L-13), 1 partial (L-8), 1 regressed-still-Low (L-15), 15 open.
New: **2 High** (R2-H1 curator drain, R2-H2 unrecognised reserve loss), **2 Medium** (R2-M1 owner voids first-loss layer, R2-M2 Wrapper inflation), 7 Low (2 demoted from Medium: invest-liquidity, circuit-breaker). Verification ledger: `findings/verify/_LEDGER.md` (7 verdicts: 5 confirmed, 2 demoted, 0 cut).
Hypotheses: N1 ✔ High · N2 ✔ High + Low · N3 refuted (pot/queue exact) · N4 refuted (no drift) · N5 refuted (not a cliff) · N6 ✔ Medium · N7 ✔ Medium · N8 partly (dry-run gaps Low; clamp Low) · N9 refuted (hooks harmless) · N10 dead surface (Info) · N11 Info · N12 refuted.
Report: `cap-v2-audit-report-r2.md`. Fuzz: lead suite I1–I19 deep run in `tests/invariants/deep-run.log`; workstream suites under `tests/scratch/*/`.
