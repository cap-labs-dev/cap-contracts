# Cap v2 — Security & Economic Audit

**Branch:** `cap-network` @ `3c45dca` · **Toolchain:** forge 1.6.0-nightly, solc 0.8.36, OpenZeppelin 5.7.0 (verified byte-identical to the registry) · **Date:** 2026-09-09

---

## 1. Executive summary

**Verdict: not safe to ship as-is.** One Critical, two Highs and five Mediums survived adversarial verification. Every finding at Medium or above has a Foundry test that fails on the current code. Nothing in `contracts/` or `test/` was modified.

| Severity | Count | Findings |
|---|---|---|
| **Critical** | 1 | C-1 oracle answers 8 decimals, tranche consumes 18 — capital understated 1e10×; first liquidation seizes the whole tranche for dust |
| **High** | 2 | H-1 Underwriter redeems at a stale post-slash mark (loss transferred to stayers); H-2 queue settlement is order-dependent — a queued claim drains locked collateral and pushes a healthy market under `lt` |
| **Medium** | 5 | M-1 one stale feed bricks liquidation for the whole market; M-2 fixed-rate EMA defeated by a par, fee-less deposit (23×); M-3 JIT depositors take a whole-term premium for 6 h of exposure; M-4 par exits before the discretionary write-off shift the shortfall to survivors; M-5 fixed loan-id reuse avoids 95 % of premium |
| Low | 21 | §4.4 — includes two demoted Mediums (inert floating multiplier; phantom yield on defaulted loans) and the I3 rounding drift the fuzzer found |

**What blocks launch (in order):**
1. **C-1.** With the only oracle in scope, the protocol cannot lend (credit ≈ 1e-10 of intended) and, on the dust it *can* lend, the first liquidation hands the entire tranche to the liquidator. This is a one-line scale fix plus a test that wires the real `Oracle` through a tranche — the 399 green tests never do, because `MockOracle` declares 8 decimals and is fed 18.
2. **H-2.** Cap every queued payout at live `unlockedSupply()`. Without it the redemption buffer — the mechanism that keeps a redemption from making a market liquidatable — does not hold on tranches.
3. **H-1.** Re-mark every allocated tranche before any Underwriter share-price consumer runs, and expose a permissionless `mark()`.
4. **M-1 through M-5** are each a bounded, verified loss to lenders or underwriters with a specific fix; none requires redesign. M-2 (EMA) and M-4 (recognition lag) are the two where the *first* proposed fix was rejected by the verifier as unsafe — see the recommendations for what to do instead.
5. **Before any deploy:** the production deploy path does not compile, hides itself from `forge build`, and defaults the liquidity-premium sink to the deployer's EOA (L-8); four `restricted` selectors reach ADMIN by omission (L-7); there is no timelock anywhere and the four beacons sit outside the AccessManager (§3.2).

**What held.** The cUSD reserve identity (`underlying held == unlockedSupply`) holds with equality through every path; the bad-debt haircut curve is exact to the wei across 7,020 cases; the 16-invariant suite passes at 5,000 runs × 1,000,000 calls; storage layout is collision-free; the ERC-7540 receipt/operator model is sound. The core accounting is careful. The defects are at the *boundaries* — where one contract consumes a number another contract owns without checking its scale or its freshness — and in a test suite whose doubles disagree with production exactly there (§7).

**Economics in one line:** at a fully-drawn line, depositors first lose at a **49 % correlated collateral drop** (health < 1 at 37.5 %); the first liquidation clears 58 % of debt and kills the junior tranche every time; underwriting is negative-EV below a **2.04 %** underwriter rate, which the *borrowing* side sets with a floor of 0; and the minted-yield "reserve clock" is slow (4.5 years to a 5 % reserve at 80 % utilization) — a design property to monitor, not a bug.

**Decisions needed from Matt:** (a) which scale to standardise on for C-1 (rescale in `Tranche` vs. 18-dec `Oracle`) — both are small, the first is smaller; (b) whether `liquidate` should be opened beyond a single LIQUIDATOR address (the models put the loss from liquidator absence at 4–12 % per 30 days at high vol, and the par burn is enforced by `_repay` regardless of caller); (c) whether `stakedStablecoin`/stcUSD — out of this repo — is the next audit target, since every liquidity premium the protocol mints lands there.

---

## 2. Scope and methodology

### 2.1 What was audited

All 39 Solidity files under `contracts/` on `cap-network`, read end to end at least once by the lead and again by the owning workstream. This branch is a ground-up rewrite: `git diff main...HEAD` is +18,095/−31,800 across 413 files, and none of v1's Minter, FractionalReserve, FeeAuction, or Symbiotic/EigenLayer delegation survives. The only external code is OpenZeppelin 5.7.0 and `forge-std`.

| In scope | Notes |
|---|---|
| `contracts/cap/**` — `Registry`, `Vault`, `Stablecoin`, `Tranche`, `Underwriter`, `InterestRateModel`, `BeaconFactory`, `market/{Base,Fixed,Floating}Market`, `oracle/{Oracle,ChainlinkAdapter}` | Core protocol |
| `contracts/ERC7540/**`, `contracts/utils/**` | Async-redeem base, vesting, math, roles |
| `contracts/deploy/**` | Ships in the production build; sets initial access-control wiring |
| `contracts/interfaces/**` | Read for documented intent vs. implementation |

| Out of scope | Why |
|---|---|
| `script/**` | Dead v1 code; not on the foundry build path (`foundry.toml` `script = "scripts"` typo); does not compile |
| `node_modules/@openzeppelin/*` | `diff -rq` against `npm pack` of 5.7.0 is empty |
| `stcUSD` (the `stakedStablecoin` yield token) | **Not in this repository.** `Registry.stakedStablecoin` is an externally supplied address to which liquidity premium is minted. The brief's "stcUSD share-price monotonicity" cannot be audited here. |
| v1 on `main` | Per scope decision |

### 2.2 Environment caveats (read before reproducing)

- **Dependency drift.** The working tree had OpenZeppelin 5.6.1 installed while `package.json`, `package-lock.json` and `yarn.lock` all pin 5.7.0. The audit installed 5.7.0 (`npm install … --no-save`; no manifest touched) and every number in this report is against 5.7.0. A stale 5.6.1 tree changes the ERC-4626 rounding internals under `Tranche` and `Stablecoin`.
- **Test discovery.** `foundry.toml` sets `test = "test"`. Everything the audit added lives under `audit/tests/` and is run with `FOUNDRY_TEST=<dir> forge test …` so the repo config is untouched.
- **Stale artefacts.** `lcov.info` and `coverage/` are dated April 2025 and describe v1. Not cited.

### 2.3 Method

1. **Phase 0** — pin the environment, verify third-party code, baseline build (exit 0) and tests (399 pass).
2. **Phase 1** — the lead read every contract and wrote 16 system invariants and 15 ranked attack hypotheses (`audit/00-plan.md`), then ran seven parallel workstreams (A reserve/peg, B async queue, C coverage/tranches/curator, D markets/liquidation, E rates/oracle, F access/upgrades/deploy, G economic models). Each was required to read its files end to end and to attach a **failing Foundry test** to every Medium-or-above claim.
3. **Phase 2** — a handler-based invariant suite over a full deployment (`audit/tests/invariants/`), run at the default profile and under `[profile.deep]` (5,000 runs × depth 200).
4. **Phase 3** — every Critical/High/Medium finding was handed to a fresh subagent whose only job was to **disprove** it, under production wiring, before it entered this report. Verdicts are in `audit/findings/verify/`.

Ground rules: NatSpec claims of safety were treated as hypotheses; no Medium+ finding is reported without a failing test or a model threshold; gas/style is a single unranked appendix.

### 2.4 Reproduction

```
# environment
npm install @openzeppelin/contracts@5.7.0 @openzeppelin/contracts-upgradeable@5.7.0 --no-save
forge build && forge test --no-match-path 'test/noTest/*'          # 399 pass

# proofs (one directory per workstream; every Medium+ finding names its test)
FOUNDRY_TEST=audit/tests/scratch/<WS> forge test --match-path 'audit/tests/scratch/<WS>/*' -vv
# or the whole tree at once (excluding the lead invariant suite):
FOUNDRY_TEST=audit/tests forge test --no-match-path 'audit/tests/invariants/*'
#   -> 47 test suites, 158 tests: 47 FAIL (the PoCs, by design), 111 PASS (controls, refutations,
#      verification tests, workstream fuzzes). Log: audit/tests/all-pocs.log

# invariants
FOUNDRY_TEST=audit/tests/invariants forge test --match-path 'audit/tests/invariants/*' -vv
FOUNDRY_PROFILE=deep FOUNDRY_TEST=audit/tests/invariants forge test --match-path 'audit/tests/invariants/*'

# economic models
python3 audit/models/<name>.py          # see audit/models/README.md
```

---

## 3. Trust model — as derived from the code

### 3.1 Roles and what each can actually do

The protocol is governed by one OpenZeppelin `AccessManager` with eight fixed roles plus per-instance operator/depositor roles minted by `Registry`. The table below is **derived from `contracts/deploy/service/ConfigureAccessControl.sol` and `Registry.sol`**, not from the docs; the full 61-selector table with wiring provenance is in `audit/findings/F.md`.

| Role | Holder (production) | Worst honest mistake | Worst malicious action | Moves depositor funds without matching accounting? |
|---|---|---|---|---|
| ADMIN (0) | `users.admin`, **and the Registry** | Repoint `Tranche.deposit` to PUBLIC; `addTranche` of the wrong asset | `upgradeToAndCall` any singleton; `addTranche(malicious)` grants ERC-6909 operator over an Underwriter's whole Vault balance | **Yes** — by design, with no delay |
| Beacon owner | `users.admin` via `Ownable` — **outside the AccessManager** | Upgrade to wrong impl | Replace the code behind every tranche/market/underwriter and walk the Vault | **Yes**, instantly, invisible to `AccessManager.canCall` |
| REGISTRY (5) | Registry | — | Grant any operator role; `BeaconFactory.create` with any beacon | Indirect: Registry also holds ADMIN, so **a Registry upgrade is full protocol control** (acknowledged at `Registry.sol:31-39`) |
| GOVERNOR (2) | `users.governor` | Unbounded `setLiquiditySlopes` (a value ≥ 3.4e11 ray bricks every floating market and the setter itself) | Same, deliberately | Indirectly, via minted yield |
| GUARDIAN (1) | `users.guardian` | `setLt` below `ltv` makes a market instantly liquidatable; `setBuffer` near `lt` locks every tranche | Collude with LIQUIDATOR (bounded by bonus ≤ 10%) | Bounded and accounted; `writeOff` socialises to cUSD holders bounded by `unrecoverableDebt` |
| KEEPER (3) | `users.keeper` | `extendAdmin` rolls a defaulted loan (documented) | Cannot enable borrowing alone (fresh market has `ltv = 0`, `fixedCreditLimit = 0`) | No |
| LIQUIDATOR (7) | `users.liquidator` — **one address** | Absent → nothing clears debt | Re-entrant liquidation with a hook-token collateral (F-4/D8) | Only via the hook path |
| MINTER / MARKET | every market | — | n/a (protocol code) | No; `Tranche.slash` additionally checks `msg.sender == market` |
| Market owner (≥100) | per market | `setUnderwriterRate(0)` — no floor, no notice | Admit anyone as tranche depositor; be the borrower too (`_createMarket` allows owner == borrower) | No direct withdrawal |
| Borrower (≥100) | per market, one address | Over-borrow within limit | Default | Yes — that is the credit risk underwriters price |
| Curator (≥100) | per underwriter | Allocate into a bad tranche | Cannot exit to self (redeem goes to `address(this)`) | No |
| Anyone | — | — | `Vault.deposit` re-entry (no profit found), `updateLiquidityRate` spam (63 %/100 % EMA regime), `requestRedeem` spam | No |

### 3.2 Where reality diverges from the documented model

1. **Four `restricted` selectors reach role 0 by omission**, not decision: `InterestRateModel.setAveragingPeriod` (the GOVERNOR array is sized 3 for a 4-member family) and `Oracle.setSource/setBackup/setChain` (no Oracle is deployed or wired anywhere under `contracts/deploy/**`). `RoleTable.t.sol` claims to pin "all 49 gated selectors" but runs against `test/shared/CapDeployer.sol`, a hand-copied mirror with the same omission; there are 61 restricted selectors. It pins the test deployer, not production.
2. **No timelock exists anywhere.** Every grant has `executionDelay = 0`; no target has an admin delay. The four `UpgradeableBeacon`s are `Ownable(users.admin)` outside the AccessManager entirely.
3. **The production deploy path does not work.** `script/DeployInfra.s.sol` does not compile (`UsersConfig` 8 vs 9 fields), `foundry.toml`'s `script = "scripts"` typo hides it from `forge build`, `DeployInfra`'s `address(this)` nonce math is refused by `forge script` under broadcast, and `WalletUsersConfig` defaults `stakedStablecoin` — the sink for **every liquidity premium the protocol mints** — to the broadcasting EOA. Whatever reaches mainnet will be wired by hand, outside the code reviewed here.
4. **The oracle scale contract is enforced nowhere** (see C-1): `Oracle` answers 8 decimals, `Tranche` consumes 18, `MockOracle` declares 8 but is fed 18, and no test wires the real oracle through a tranche.
5. **`stcUSD` is out of repo.** The brief describes depositors staking into stcUSD for yield; here `stakedStablecoin` is just an address the markets mint to. Its share-price behaviour cannot be audited from this codebase.
6. **Liquidation is a single privileged, self-funded actor.** `liquidate` is LIQUIDATOR-only and the liquidator must hold and burn cUSD at par; if that address is offline or under-capitalised, no one else can act (modelled: P(cUSD loss in 30 d) 4 % at 100 % vol, 12 % at 150 %, and ~\$30M of cUSD needed to restore a \$50M market from health 1.0).
7. **Registry defaults bypass the markets' own setters.** `lt`, `buffer`, `targetHealth` are stored unvalidated at `Registry.initialize` with no setter; `lt == buffer` bricks every tranche exit and `targetHealth < (1+bonus)·lt` bricks liquidation on every market born from it. The shipped constants happen to be valid.

### 3.3 Storage and upgradeability (verified, not a finding)

All twelve `cap.storage.*` ERC-7201 slots and seven inherited OpenZeppelin namespaces were recomputed with `cast` and cross-checked against `forge inspect` — the three hand-rolled constants (`BaseMarket`, `ERC7540AsyncRedeem`, `ERC7540Operator`) match exactly and no two regions overlap. Every implementation calls `_disableInitializers()`; every proxy is initialised in its creation transaction. The only real upgrade hazard is that `PremiumVesting.Schedule` and the IRM structs are embedded by value, so appending a field shifts every later variable (F-I7). H13 (storage collision) is **not confirmed**.

---

## 4. Findings

Severity is impact × likelihood (Immunefi-style). Every Critical/High/Medium below (a) has a Foundry test that fails on current code, (b) was handed to a fresh subagent tasked with disproving it, and (c) survived. Verdicts and corrections are in `audit/findings/verify/`; two Mediums were demoted to Low by that pass and appear in §4.4. Workstream files (`audit/findings/{A..G,LEAD}.md`) carry the full write-ups.

### 4.1 Critical

### [CRITICAL] C-1 — The oracle answers in 8 decimals; every USD figure in the credit system consumes it as 18. Capital is understated 1e10×, borrowing is fail-closed, and the first liquidation of any market seizes the whole tranche for dust
**Location:** `contracts/cap/oracle/Oracle.sol:16-18` (`DECIMALS = 8`, `ONE = 1e8`), `contracts/cap/oracle/ChainlinkAdapter.sol:57-61` (normalises to 8); consumed unscaled at `contracts/cap/Tranche.sol:83-89` (`slash`), `:274` (`unlockedSupply`), `:281-288` (`totalCapital`, `activeCapital`); documented as USD 18 decimals at `contracts/interfaces/ITranche.sol:22,59,61,153,157`.
**Impact:** `Tranche.totalCapital = totalAssets · price / 10**decimals` returns USD in the *price's* scale. With the only oracle in scope that is 8 decimals, so `totalCapital`, `activeCapital`, `variableCreditLimit`, `debtLiquidationThreshold`, `recoverableDebt`, `maxLiquidatable` and `lockedValue` are all compared against 18-decimal cUSD debt 1e10× too small. Three consequences, each demonstrated: (1) 10 WETH at \$2,000 opens **1e12 wei = 0.000001 cUSD** of credit — the protocol cannot lend; (2) that dust of debt locks **71 %** of the tranche's shares — underwriters cannot redeem; (3) `slash` converts `value · unit / price` at the 8-dec price, so a liquidation of **5.9e-7 cUSD** resolves to 1e19 wei of WETH, is capped at the tranche's balance, and **hands the LIQUIDATOR all 10 WETH**. The verifier's own test with no price move at all shows an honest target-health liquidation after ordinary premium accrual paying 7.87 WETH for 1.5e-6 cUSD — exactly 1e10× the intended 7.87e8 wei. Dollars at risk: the entire collateral of every tranche whose market ever dips under `lt` (≈79 % per liquidation with no price move; 100 % once `maxLiquidatable` hits the tranche cap).
**Likelihood:** Certain on any deployment that prices through the shipped `Oracle` + `ChainlinkAdapter`. There is no intended 18-decimal oracle anywhere: `DeployInfra` takes `users.oracle` from config, `WalletUsersConfig` never sets it, `script/manage/*` imports a deleted v1 oracle, and the v1 mainnet oracle in `config/cap-infra.json` is also 8-decimal and does not implement `price()`. The suite never sees it because `test/shared/mocks/MockOracle.sol` declares `DECIMALS = 8` while `CapDeployer` feeds it `1e18`; the oracle unit tests assert `2000e8` and never touch a tranche. No attacker capital: the seize path runs on the LIQUIDATOR role's intended use, with a caller-supplied recipient.
**Exploit path:** 1. Governance wires `Oracle.setSource(WETH, ChainlinkAdapter.price(feed))`; a market is created with a WETH tranche; an underwriter deposits 10 WETH (\$20,000). 2. `creditLimit()` = 1e12 wei; the borrower draws it. 3. WETH falls ≥ 38 % (or ~3 years of premium accrual pass). 4. Liquidator deposits 5.9e-7 USDC → cUSD, calls `liquidate(recipient, max)`: `toSlash = 6e11`; `Tranche.slash` computes `6e11 · 1e18 / 600e8 = 1e19` → capped at `totalAssets` → `Vault.withdraw(WETH, 10e18, recipient)`. 5. Recipient +10 WETH (\$6,000 real); underwriters −100 %; the `Slashed` event reports value `6e11`.
**Proof:** `audit/tests/scratch/LEAD/OracleDecimals.t.sol` (scale), `audit/tests/scratch/E/E1_OracleDecimals.t.sol` (real `Oracle` proxy + `ChainlinkAdapter` + `MockAggregator(8, 2000e8)` through a fresh `Registry`):
```
[FAIL: totalCapital is 1e10x below the documented scale: 2000000000000 != 20000000000000000000000] test_totalCapital_isDocumentedEighteenDecimalUsd()
[FAIL: credit limit is 1e10x below intended: 1000000000000 != 10000000000000000000000] test_creditLimit_isTenThousandDollars()
[FAIL: 1e-6 cUSD of debt locks 71% of a $20k tranche: 2857142857145000000 < 9999998999285714286] test_dustDebtLocksMostOfTheTranche()
[FAIL: liquidator seized 1e10x more collateral than the debt cleared: 6000000000000000000000 > 600600000000] test_liquidation_takesWholeTrancheForDust()
  cUSD burned by liquidator (wei): 588235294118   WETH seized (wei): 10000000000000000000   WETH left in tranche (wei): 0
```
Verification: `audit/findings/verify/CRIT-ORACLE-DECIMALS.md` — CONFIRMED.
**Recommendation:** Pick one scale and enforce it at the boundary. Smallest change: `Tranche` reads `IOracle(oracle).DECIMALS()` once at init and computes `capital = assets · price · 10^(18 − oracleDecimals) / 10^decimals()` (and the inverse in `slash`/`unlockedSupply`). Alternatively make `Oracle.DECIMALS = 18` and rescale in the adapter. Then: make `MockOracle` honour its own `DECIMALS` so the suite fails on a mismatch; add one integration test that deploys the real `Oracle` + `ChainlinkAdapter` under a tranche; assert `IOracle(oracle).DECIMALS()` in `Registry._deployTranche`. Second-order: an 18-dec `ONE` changes chain-composition rounding (each leg floors at 1e-18 instead of 1e-8 — strictly better).
**Invariant broken:** I5 (liquidation "profitable" by 1e10×), I8 (true but meaningless), and the implicit bound at `BaseMarket.sol:337-338` "the tranches never give up more than `1 + bonus` per unit of debt cleared" — proposed as a new invariant.

### 4.2 High

### [HIGH] H-1 — Underwriter depositors redeem at a stale mark after a tranche slash, extracting the loss from those who stay
**Location:** `contracts/cap/Underwriter.sol:345-347` (`totalAssets`), `:193-209` (`_mark`), `:377-379` (`unlockedSupply`); the inherited, ungated `redeem`/`withdraw`/`requestRedeem`/`redeem(requestId)`.
**Impact:** `Underwriter.totalAssets() = idle vault balance + totalDebt`, where `totalDebt` is a cached valuation refreshed only inside `allocate`, `deallocate*`, `finalizeDeallocateAsync` and `report` (KEEPER). Every share-price consumer reads the cache. Between a slash and the next mark, any share holder redeems at the pre-slash price, paid from the idle balance. The staleness is one-directional — a tranche's NAV only moves between marks via `slash` (deposits mint at par; premium is a separate cUSD leg that never enters the share price) — so every exit in the window is a transfer from the remaining holders to the exiter. In the PoC (two equal depositors, 50 % allocated, one liquidation slashing 170 of 500) the exiter is paid 500 against a fair 415 and the remaining depositor drops to 330: **85 tokens, 20 % of his fair share, silently**, while the vault reports itself healthy. Bound (verified to the wei): cumulative extraction ≤ `idle · L / A_stale`; zero when everything is allocated, but instant redemption is *defined* as `previewWithdraw(idle)`, so any vault that offers exits carries the idle that makes it extractable.
**Likelihood:** Needs no role — the verifier showed a never-admitted transferee of shares redeems at the stale price. Trigger is an ordinary liquidation (public `Liquidate`/`Slashed` events; a redeem can be bundled in the same block). Idle balance exists whenever the curator keeps a buffer, runs more than one tranche, or has settled an async deallocation. `IUnderwriter.debt` NatSpec itself calls the figure "an upper bound" refreshed on a keeper cadence.
**Exploit path:** 1. Underwriter holds 1000 (A 500, B 500); curator allocates 500 to tranche T, keeps 500 idle. 2. Market borrows 250 against T; collateral falls 40 %; LIQUIDATOR repays 100 and slashes 170 tokens from T. True assets 830; `totalAssets()` still 1000. 3. A `redeem(500)`: `maxRedeem = min(500, previewWithdraw(500 idle))` at the stale price → A receives 500 (fair 415). 4. KEEPER `report(T)`: `totalDebt` → 330; B's 500 shares are worth 330. Net A +85, B −85. The queued path pays identically.
**Proof:** `audit/tests/scratch/C/C1_StaleMark.t.sol`:
```
[FAIL: exiting depositor must not be paid above the true share price: 499999999999999998500 > 414999999999999998841] test_H2_exitAtStaleMarkAfterSlash()
  alice fair share: 414999999999999998840   alice actually paid: 499999999999999998500   bob loss transferred from alice: 84999999999999998660
[FAIL: queued claim paid at stale mark: 499999999999999998500 > 414999999999999998841] test_H2_queuedExitAlsoAtStaleMark()
```
Verification: `audit/findings/verify/HIGH-STALE-MARK.md` — CONFIRMED; corrections: a 1-wei `deposit` does re-mark the *default* tranche (so "no permissionless re-mark" is overstated for that one tranche), and the attacker set is any share holder.
**Recommendation:** Price every entry and exit off a live mark: override `deposit`/`mint`/`withdraw`/`redeem` (both overloads) to `_mark` every tranche with `debt[t] > 0` *before* the preview is taken (the OZ `redeem` computes `previewRedeem` before `_withdraw`, so an `_onWithdraw` hook is too late), and expose a permissionless `mark(tranche)`. `_mark` needs no oracle so the loop cannot be bricked by a stale feed; gas is linear in tranche count, which the curator controls. Keep `report` for the premium sweep only.
**Invariant broken:** I16. New: `Underwriter.totalDebt == Σ previewRedeem(balanceOf(t) + queuedShares[t])` at every mint/burn.

### [HIGH] H-2 — Queue settlement is order-dependent: a later request that settles first permanently over-credits every earlier open request, so a queued claim can drain collateral the market reports as locked and push a healthy market under `lt`
**Location:** `contracts/ERC7540/ERC7540AsyncRedeem.sol:123-140` (`claimableRedeemRequest`), `:226-247` (`_withdraw` queued, `settledQueue += _shares` at L241); consumers `contracts/cap/Tranche.sol:271-278`, `contracts/cap/Underwriter.sol:377-379`.
**Impact:** `claimableRedeemRequest` treats `settledQueue + unlockedSupply()` as a cumulative liquidity high-water mark over positional windows. That is only correct if settlement happens in queue order; the code lets a later request claim as soon as its own window is under the mark, and its settled shares then credit every earlier open window as if they were liquidity at the head of the queue. On `Stablecoin`, `unlockedSupply` only falls through claims themselves, so the mark never drops below a claimed position (fuzzed: 16,000 calls, 0 violations). On `Tranche`/`Underwriter` it falls exogenously — borrow, accrual, price, slash, `allocate` — and the over-credit becomes real: the earlier request is paid while `unlockedSupply() == 0`, i.e. the tranche is drained below `lockedValue`. The buffer exists precisely so redemptions cannot move a market from healthy to liquidatable; in the PoC one queued claim moves `healthiness()` from 1.12 to 0.896 and `maxLiquidatable()` from 0 to 407e18; the remaining holders are then slashed with the bonus, and at over-credits ≥ ~29 % of the tranche the residual is written off onto cUSD holders. On `Underwriter` the view misreports and the claim reverts inside `Vault.transfer` (liveness, not theft).
**Likelihood:** Unprivileged, production `buffer = 0.1e27`, organic trigger. The verifier reproduced it without the PoC's shortcut: both requests made while the tranche was fully locked (async is the only exit), unlocked by an ordinary borrower `repay`, the later request claimed first by a faster holder, re-locked by a price move that leaves the market healthy exactly at the buffer floor (`lt/(lt−buffer) = 1.1428`, where `liquidate` reverts `Healthy`). The canonical slow claimant is the Underwriter's keeper-finalized `deallocateAsync`.
**Exploit path (organic):** 1. Senior-only market, supplier 800 + Alice 200 at \$1; borrower draws 500; `unlockedSupply ≈ 285.7`. 2. Alice `requestRedeem(200)` → window `[0, 200)`, fully claimable; she waits. 3. Carol, Dave, Erin each deposit 80, request and claim; `settledQueue = 240`. 4. Collateral −30 %: `unlockedSupply() = 0`, `healthiness() = 1.12`. 5. Alice `redeem(idA, 200)` succeeds: `claimable = min(200, 240 + 0)`. 6. `healthiness() = 0.896`, `maxLiquidatable() = 407.8`; the LIQUIDATOR slashes 552 collateral units — **69 % of the remaining holder's position** — that the buffer was designed to make untouchable.
**Proof:** `audit/tests/scratch/B/B1_OutOfOrderSettlement.t.sol` (3 failing), `B1b_ControlAndUnderwriter.t.sol` (control passes, proving order-dependence), and the handler fuzz in `B_QueueInvariants.t.sol` shrinks it to six calls:
```
[FAIL: claimable must never exceed unlockedSupply: 99999999999999999000 > 0] test_B1_juniorClaimSucceedsWhileUnlockedSupplyIsZero()
[FAIL: a redemption must never make a healthy market liquidatable: 896000000000000000000000000 < 1000000000000000000000000000] test_B1_seniorExitFlipsHealthyMarketToLiquidatable()
[FAIL: sum claimable <= unlocked (tranche): 13648702 > 0]  [Sequence] (original: 120, shrunk: 6)  deposit  request  request  borrow  claim  price(0)
```
Verification: `audit/findings/verify/HIGH-QUEUE-OUT-OF-ORDER.md` — CONFIRMED; correction: the "deliberate pre-credit" attacker framing in B.md is dominated by instant exit and only pays if the actor also holds LIQUIDATOR — the real vector is the organic slow claimant.
**Recommendation:** Cap every queued payout by live liquidity: in the queued `_withdraw` revert if `_shares > unlockedSupply()`, and return `min(positional, unlockedSupply())` from `claimableRedeemRequest`. Positional priority is preserved (an over-credited early request still takes the first liquidity that returns). Lift `Σ claimable ≤ unlockedSupply` from `B_QueueInvariants.t.sol` into the permanent suite over `Tranche` and `Underwriter`.
**Invariant broken:** I15 (Tranche/Underwriter), I5/I8 indirectly. New: `Σ_open claimableRedeemRequest ≤ unlockedSupply()`.

### 4.3 Medium

### [MEDIUM] M-1 — One stale oracle feed on any tranche bricks liquidation, write-off, borrowing and every tranche's redemption for the whole market
**Location:** `contracts/cap/Tranche.sol:328-331` (`getPrice`), `:271-278`, `:281-288`; `contracts/cap/market/BaseMarket.sol:270-292` (`lockedValue`, `totalCapital`), `:217-221`, `:245-267`, `:350-353`.
**Impact:** Every market-level figure is `Σ Tranche.totalCapital()`, and each term reverts on its own stale/zero price. A dead feed (primary and backup) on a 0.1 % junior tranche makes `healthiness`, `maxLiquidatable`, `unrecoverableDebt`, `availableCredit`, `liquidate`, `writeOff` and the senior's `maxRedeem` all revert while `repay` and premium accrual keep running. `Tranche.getPrice` NatSpec argues fail-closed for *that tranche's own* figure; it does not consider that the sum couples every tranche. The verifier ran a matched price path: with live feeds the market liquidates twice and leaves 0 unrecoverable; with the outage it leaves the senior wiped and **49.6 cUSD of avoidable bad debt on cUSD holders** per 500 of debt. The claimed ADMIN `setTranches` escape hatch reverts `Unhealthy()` in exactly the crash scenario; the only working remedy is ADMIN re-pointing the feed (role 0, no delay).
**Likelihood:** No attacker; a double-feed outage on an asset governance chose, coinciding with a crash on the priced collateral, plus governance latency. Multi-asset markets are a first-class feature and long-tail collateral is what a junior tranche is for.
**Proof:** `audit/tests/scratch/C/C3_OracleBricksLiquidation.t.sol` — `[FAIL: PriceError(0x3Cff…)] test_oneStaleFeedBricksLiquidationAndRedemption()` with `healthiness/maxLiquidatable/unrecoverableDebt/availableCredit/writeOff/senior.unlockedSupply/senior.maxRedeem: REVERT`, `repay: ok`. Verification: `audit/findings/verify/MED-STALE-FEED-BRICKS.md` — CONFIRMED.
**Recommendation:** Fail *safe* in the aggregates: treat a tranche whose price is unavailable as zero capital in `totalCapital`/`lockedValue` (conservative for health, borrowing and liquidation), keep the revert in `slash` itself, and let `_liquidate` skip an unpriceable tranche and continue up the waterfall. Pair with a per-tranche grace window in `Oracle` so a transient outage on a large tranche does not make a healthy market look liquidatable.
**Invariant broken:** I5 cannot be evaluated.

### [MEDIUM] M-2 — The utilization EMA is defeated by a par, fee-less, instantly-reversible cUSD deposit held for one window; a fixed-rate borrower reprices a 30-day loan at 23× the cost
**Location:** `contracts/cap/InterestRateModel.sol:181-189` (`fixedRatesAfterMint`), `:251-254`, `:280-316` (EMA), `:228-234` (band 5 min – 1 day); `contracts/cap/market/FixedMarket.sol:307-322`; `contracts/cap/Stablecoin.sol:162-187`.
**Impact:** stcUSD holders receive less than the curve prices for the whole term. On a \$1M/30 d loan against 80 % utilization, parking \$10M for the default 1 h window cuts the liquidity premium **8,966 → 6,311 cUSD (−30 %)** for ≈ 114 cUSD of opportunity cost (23×; 279× at the 5-min floor; 7.6× at the 1-day ceiling on \$5M). WS-G's model: at u 90 %, \$100M parked one window saves \$61k on \$10M for \$13.7k (1 day) or \$68 (5 min); break-even D < 0.1× supply at every period. The NatSpec's "standing behind an unwanted position … exposed to everyone else" claim is false for the supply-dilution direction: a cUSD deposit is redeemable at par in the same block (`unlockedSupply` rises by exactly `D`; verified even with a pre-existing queue), earns nothing and risks nothing while `badDebt == 0`. The `mintAmount` plumbing adds `L` to both sides of the ratio and cannot touch the `D` dilution.
**Likelihood:** The park needs no role; the borrow needs the market's BORROWER, who is precisely the adversary the averaging defends lenders against. Capital of the order of the stablecoin's supply, for ≤ 1 day. Discount bounded by the slope portion of the curve (rate floors at `base`).
**Proof:** `audit/tests/scratch/E/E2_EmaManipulation.t.sol` — `[FAIL: a fully reversible deposit repriced a 30-day loan: 6311154598825831702544 != 8966376089663760896637]`, `[FAIL: see log: profitable across the whole band]` (5 min / 1 h / 1 day). Model: `audit/models/ema_manipulation.py`. Verification: `audit/findings/verify/MED-EMA-MANIPULATION.md` — CONFIRMED (figures recomputed independently; slopes are the test deployer's, not a production config).
**Recommendation:** Price the fixed premium off `max(averageUtilizationAfterMint, spotUtilizationAfterMint)`: a deposit withdrawn before the borrow no longer helps, and one still present is real liquidity. Alternatively exclude supply younger than one window from the averaged supply. Raising the band cannot fix it — the band bounds duration, not profitability.
**Invariant broken:** none listed. New: a fixed premium is never charged below `_nextLiquidityRate(utilizationRateAfterMint(principal))`.

### [MEDIUM] M-3 — Premium is attributed to whoever holds shares when it arrives, not to whoever carried the exposure: a depositor present for six hours of a 30-day fixed loan takes its pro-rata share of the whole term's premium and leaves
**Location:** `contracts/utils/PremiumVesting.sol:114-116` (`fund` restarts the epoch to *current* holders), `contracts/cap/Tranche.sol:118-124` (`notifyPremium`), `contracts/cap/Underwriter.sol:229-240` (`report`), `contracts/cap/market/FixedMarket.sol:296-318` (whole-term premium charged at borrow).
**Impact:** The per-share accumulator credits a lump to whoever is staked from the moment it is funded, over the next 6 h. `FixedMarket` charges the whole term's premium at borrow, so an admitted depositor arriving any time inside the 6 h window after a `borrow` collects a pro-rata share of a 30-day premium and then instant-redeems everything the buffer leaves unlocked (`unlockedSupply` only pins `totalDebt/(lt−buffer)`). In the PoC Carol doubles the tranche, takes **50 % of a 30-day premium for 6 h of exposure, and redeems 100 % of her collateral**, leaving Alice alone for the remaining 714 h at half the pay. The same window precedes every Underwriter `report`. Roughly 120× the honest 6 h yield.
**Likelihood:** Attacker is an admitted depositor (tranche or Underwriter). No front-running needed — the verifier's back-run test arriving 1 h late still nets 5/12 of the lump. 6 h of slash exposure on a fresh ltv-0.5 loan is negligible. `setVestingPeriod(term)` cuts the take to 41 bps but fixed markets have variable terms and every `fund` restarts the epoch, so it is not an existing mitigation.
**Proof:** `audit/tests/scratch/C/C2_JitPremium.t.sol` — `[FAIL: carol collected half a 30-day premium for 6 hours of exposure, then left: 4109589041095890412 != 0]`, `[FAIL: a depositor absent during accrual should earn nothing from it: 3314841198817717851 != 0]`. Verification: `audit/findings/verify/MED-JIT-PREMIUM.md` — CONFIRMED; correction: the Underwriter-path depositor cannot self-exit (`maxRedeem = 0` because `Underwriter.totalAssets` omits the tranche's claimable receivable), so that variant is a mis-attribution without the exit.
**Recommendation:** Vest over the *risk* period: for fixed loans have `notifyPremium` take a period equal to the term (or stream the term premium through the floating-style index instead of minting it at once). At minimum checkpoint entry time and pro-rate the first epoch. For the Underwriter, make `report` permissionless (removes the cadence signal) and carry the tranche's accrued-but-unclaimed premium in `totalAssets` so a JIT deposit pays for it in the share price.
**Invariant broken:** none listed. New: premium credited to an account is proportional to `∫ balance · dt` over the accrual period.

### [MEDIUM] M-4 — The haircut curve socialises only *recognised* bad debt; between `unrecoverableDebt() > 0` and the GUARDIAN's discretionary `writeOff`, every redemption is paid at par and the shortfall lands on whoever is still holding
**Location:** `contracts/cap/Stablecoin.sol:224-249` (`_convertToAssets` uses `badDebt` only), `:109-121` (`recognizeBadDebt` — sole caller chain is `BaseMarket._writeOff` ← GUARDIAN-only `writeOff`); `contracts/cap/market/BaseMarket.sol:263-267` (`unrecoverableDebt` is public).
**Impact:** The curve's documented purpose is to make "exiting first the worst time to exit". It does exactly that for recognised bad debt (WS-G: payout/share monotone 0.816 → 0.891 along the queue). But nothing auto-recognises — not time, not redemption, not an index poke — and there is no pause on redemptions, so from the oracle tick that makes `unrecoverableDebt() > 0` until the guardian's transaction, `badDebt == 0`, `previewRedeem` is par, and the reserve pays in full. Foundry reproduction to the wei: on S 100k, reserve 20k, shortfall 10k, a 10k par exit before write-off leaves the survivors' backing at 0.8889 instead of 0.9091; the exiter keeps 1,818 the curve would have charged; a surviving 10k redeemer receives 8,000 instead of 8,349 (−3.5 %). The model: 20 % of supply leaving at par over 14 days transfers **\$2.0M** on a \$100M supply with a 10 % shortfall; the cap is the entire reserve.
**Likelihood:** Roleless — a bot watching the public view needs only its own cUSD. The lag is structural, not negligence: a write-off is permanent debt forgiveness (a dip → write-off → recovery leaves the borrower's debt reduced with collateral untouched), so a diligent guardian rationally waits out a dip before booking, and even a perfect guardian is a block behind a redeemer in the oracle-update block.
**Proof:** `audit/models/run_dynamics.py` part C; Foundry reproduction `audit/tests/scratch/verify/MED-RECOGNITION-LAG/Verify_RecognitionLag.t.sol`. Verification: `audit/findings/verify/MED-RECOGNITION-LAG.md` — CONFIRMED.
**Recommendation:** Narrow the window without making forgiveness permissionless. Two of WS-G's proposals were struck by the verifier and should **not** be adopted: a permissionless `writeOff` turns every transient oracle dip into a borrower windfall paid by cUSD holders, and a "provisional shortfall" haircut has nowhere to retire (`_onWithdraw` only retires against `badDebt`). Workable: a GUARDIAN-set *pause on instant redemptions* (queue still open) that any keeper may trigger when `Σ unrecoverableDebt() > 0`, cleared by write-off or by the shortfall disappearing; and a keeper-callable write-off bounded exactly as today but only after the shortfall has persisted for N blocks.
**Invariant broken:** the spirit of I5 and the `Stablecoin` NatSpec claim, for the pre-recognition interval. New: `Σ unrecoverableDebt() == 0` whenever `badDebt == 0`, or the gap is bounded by a recognition SLA.

### [MEDIUM] M-5 — Fixed loan ids are never bounded by `loanCount`: an unused id can be given an expiry, drawn on, and re-termed by the next `borrow`, so the owner/borrower pair pays a 1-day premium for 30 days of exposure
**Location:** `contracts/cap/market/FixedMarket.sol:64-74` (`borrow` — `id = loanCount++; expiry[id] = …` overwrites), `:77-86` (`borrowMore`), `:89-102` (`extend` — `expiry 0` reads as expired and rolls), `:105-110` (`extendAdmin`).
**Impact:** 95 % of the liquidity and underwriter premium on a maximum-term loan is avoided. At \$10M the pair pays 16,256 cUSD for 30 days against an honest 328,767 (95.05 %); repeatable monthly by chunk-migrating debt onto the next unused id (round 2: 8,951 vs 222,612). `totalDebt == creditBackedSupply` stays exact, so it is a pure silent underpayment of stcUSD holders and tranche depositors, not an unbacked mint. It defeats the one guard governance has on the liquidity price: `minimumMarketMultiplier = 1e27` stops a legitimate discount, and this path cuts it ~93 %.
**Likelihood:** No single role can do it: the borrower alone hits `LoanExpired`/`AccessManagedUnauthorized`; the owner alone cannot draw. It needs market OWNER (or KEEPER via `extendAdmin`, since `expiry 0 + grace ≤ now`) plus BORROWER — two operator addresses of the same market that the Registry permits to be one address (`_createMarket` accepts `_marketOwner == _borrower`). Cost: gas.
**Exploit path:** 1. `id = loanCount` (unused). Owner `extend(id, 1 day)`: `expiry[id] == 0` takes the `_rollFromNow` branch, `debt[id] == 0` so premium is zero; `expiry[id] = now + 1 day`. 2. Borrower `borrowMore(id, self, 4,000)`: remaining term 1 day; pays 6.50. 3. Borrower `borrow(self, 1, 30 days)`: `id = loanCount++` returns the same id, `expiry[id] = now + 30 days` overwrites. Total premium 6.54 vs 131.51 honest.
**Proof:** `audit/tests/scratch/D/D9_PhantomLoanId.t.sol` — `[FAIL: 30 days of exposure must cost the 30-day premium: 6535159817351598172 < 131506849315068493150]`. Role-isolated reproduction: `audit/tests/scratch/verify/MED-LOAN-ID-REUSE/V_LoanIdReuse.t.sol`. Verification: `audit/findings/verify/MED-LOAN-ID-REUSE.md` — CONFIRMED.
**Recommendation:** `if (id >= loanCount) revert UnknownLoan();` in `borrowMore`, `extend`, `extendAdmin`, `repay`, `liquidate`, `writeOff`; and have `borrow` assert `expiry[id] == 0 && debt[id] == 0` for the id it mints. No legitimate flow touches an id before `borrow` creates it.
**Invariant broken:** none listed. New: `id < loanCount` for every id-taking function.

### 4.4 Low

Each has a failing or documentary test in the named workstream directory; write-ups with exploit paths and recommendations are in the workstream files. Duplicates found independently by several workstreams are merged.

| # | Finding | Location | Source |
|---|---|---|---|
| L-1 | `FloatingMarket._premium`'s two-part half-up rounding walks `totalDebt` above `creditBackedSupply` (17 wei/yr; 337/365 daily accruals on the harmful side); full `repay(max)` and `writeOff()` on the last-standing market then revert on the `creditBackedSupply -=` underflow; the repo's own `test_debtNeverExceedsCreditBackedSupply` pins the opposite claim and passes only because 20 × 13 s is too short. Reproduced by the deep invariant run. Fix: derive the minted premium from the reading's own movement, as `_floorReduction` already does for reductions. | `FloatingMarket.sol:195-233`, `Stablecoin.sol:76-81` | A-1, D3 |
| L-2 | `FloatingMarket.liquidate` stores `scaledDebt` *after* the slash loop's external calls; with a hook-token collateral the LIQUIDATOR's recipient re-enters, the inner liquidation is overwritten, 200 cUSD burned for 100 of debt reduction, the whole tranche drained, and `Σ totalDebt > creditBackedSupply` system-wide. No `ReentrancyGuard` anywhere. | `FloatingMarket.sol:90-103` | F-4, D8 |
| L-3 | `FloatingMarket.borrow` has no post-borrow health assertion (unlike `FixedMarket.sol:202`); after GUARDIAN `setLt < ltv` one borrow lands health 0.8 and \$2.7k liquidatable on \$5k. | `FloatingMarket.sol:68-77` | D4 |
| L-4 | `Registry.initialize` stores `lt/buffer/targetHealth` unvalidated with no setter; `lt == buffer` makes every tranche exit revert, `targetHealth < (1+b)·lt` makes an unhealthy market un-liquidatable, on every market born from it. Shipped constants are valid. | `Registry.sol:102-124`, `BaseMarket.sol:44-56` | F-3, D5, G |
| L-5 | `setLt` permits `lt > 1/(1+bonus) = 0.9804`, at which `healthiness() ≥ 1` while `unrecoverableDebt() > 0`: every health gate passes and `liquidate` reverts `Healthy()` on a market already exposing cUSD holders. Require `lt·(1+bonus) ≤ 1e27`. | `BaseMarket.sol:82-91` | G |
| L-6 | `base/slope0/slope1/termMultiplierSlope` are unbounded; rate·time ≳ 8.8e7 ray-years overflows `_index`, bricking every stablecoin move, every floating market, **and `setLiquiditySlopes` itself** (it accrues before writing) — upgrade-only recovery. Below that, a 100× fat-finger makes every market liquidatable within days. | `InterestRateModel.sol:105-115, 169-172, 343-349` | E, G |
| L-7 | `setAveragingPeriod` and `Oracle.setSource/setBackup/setChain` reach role 0 by omission; `RoleTable.t.sol` pins `CapDeployer` (a mirror with the same omission), not production, and covers ~51 of 61 restricted selectors. | `ConfigureAccessControl.sol:59-64` | F-2 |
| L-8 | The production deploy path is broken three ways (script does not compile; `address(this)` nonce math refused under broadcast; `foundry.toml` `script = "scripts"` hides both) and defaults `stakedStablecoin` — the liquidity-premium sink — to the deployer EOA; no Oracle is deployed or wired anywhere. | `script/DeployInfra.s.sol`, `DeployInfra.sol:44-46`, `foundry.toml:7` | F-1 |
| L-9 | The floating market's multiplier is economically inert: it scales the cumulative *index*, which cancels out of the accrual ratio; 1× and 2× charge identical premium to the wei (256-run fuzz). Only `FixedMarket` (rate-scaled) responds. *Demoted from Medium: non-functional knob defaulting to 1×, nothing extractable.* | `InterestRateModel.sol:164-166`, `FloatingMarket.sol:54-65` | D1 |
| L-10 | Premium keeps being minted against debt already known unrecoverable (keeper `extendAdmin` rolls; floating accrual); 12 rolls on a \$5k loan mint \$1,650 of phantom yield. *Demoted from Medium: `totalAssets` is byte-identical with or without rolls — pure share dilution at ~0.08 %/day of the unrecoverable slice, needing KEEPER rolling plus GUARDIAN/LIQUIDATOR inaction; documented trade-off.* Do **not** auto-recognise in `_chargePremium` (oracle-wick griefing); charge on `min(debt, recoverableDebt())`, and note write-off alone is not a full brake — the residual at `recoverableDebt` re-creates a shortfall on the next roll. | `FixedMarket.sol:105-110, 285-322`, `BaseMarket.sol:438-480` | D2 |
| L-11 | Tranches with zero capital (drained or `killed`) keep receiving their full premium weight because `_chargePremium` gates on `stakedSupply`, not capital. | `BaseMarket.sol:451-467` | C, D |
| L-12 | The kill latch fires on any previously-used-and-emptied junior tranche at the first routine liquidation (1,000 dead shares > 0 assets); `maxDeposit = 0` permanently. Compare against `stakedSupply()`. | `Tranche.sol:104-107` | C |
| L-13 | Public `FloatingMarket.chargePremium()` restarts the tranche vesting epoch on every call — exactly what the Registry restricts `notifyPremium` to prevent — turning the advertised linear 6 h release into exponential decay (36 % still locked after one period with 10-min pokes). | `PremiumVesting.sol:114-116`, `FloatingMarket.sol:106-108` | C |
| L-14 | Queued shares stop earning premium but keep full slash exposure and stay counted in `healthiness`, indefinitely while the debt stands; no cancel path exists (`CancelRedeem` is declared and dead). In a single-tranche market 100 % of underwriter premium routes to stcUSD while the queued position is slashed. | `Tranche.sol:264-268`, `ERC7540AsyncRedeem.sol` | B-2, C |
| L-15 | `ChainlinkAdapter._withinBounds` fails open when `aggregator()` is missing — including a feed configured at its aggregator address that *does* publish bounds — so a LUNA-style floor is accepted. | `ChainlinkAdapter.sol:79-94` | E |
| L-16 | `Oracle._isStale` treats a future-dated stamp as fresh forever; a silent feed stays live 5 years past a 1 h window and the backup is never consulted. | `Oracle.sol:181-192` | E |
| L-17 | The EMA is accrual-frequency dependent: one window moves the average 100 % if quiet, 63 % if anyone spams the permissionless `updateLiquidityRate` every block; either party can pick the regime for gas. | `InterestRateModel.sol:280-316` | E |
| L-18 | `Vault.deposit` mints ERC-6909 before `safeTransferFrom`; a sender-hook token lets the depositor withdraw other depositors' tokens mid-call (I12 broken inside the transaction; net zero with an honest token). Flip the order. | `Vault.sol:34-37` | A, F-I2 |
| L-19 | `liquidationBonus = 0` is permitted and is indistinguishable from an offline liquidator: P(cUSD loss in 30 d) 4 % at 100 % vol, 12 % at 150 %. Floor the bonus; open `liquidate` to any caller (the par burn is what must be enforced, and `_repay` enforces it). | `InterestRateModel.sol:205-212` | G |
| L-20 | The first liquidation at health 1 clears 58 % of debt in one call (`(TH−1)/(TH−(1+b)·lt)` at defaults), wiping and permanently killing a 5 % junior in every scenario and touching the senior in the same call — a cliff, not a curve. | `BaseMarket.sol:245-255` | G |
| L-21 | Underwriter compensation is set by the *borrowing* side (market owner), has floor 0 with no notice period, and 71 % of tranche capital is locked at full draw — exactly when a negative-EV underwriter (below `(1+b)·p_default` = 2.04 %) would rationally leave. | `Registry.sol:324-330`, `InterestRateModel.sol:122-131` | E, G |

### 4.5 Informational and refuted hypotheses

Full text in the workstream files. Highlights: the reserve identity `underlyingBalance == unlockedSupply` holds with **equality** through every path (H1 refuted as a defect — it is a slow clock by design); the bad-debt haircut curve is exact to the wei (H6 refuted, 7,020 cases); par-mint during a shortfall has no in-protocol profit path; the ERC-7540 receipt/operator/allowance model is sound; every ERC-7201 slot matches and no storage region overlaps (H13 refuted); `maxLiquidatable` lands on `targetHealth` to 1e-12 (512-run fuzz); partial liquidations extract *less* than one full one; `Vault.deposit` re-entry nets zero with an honest token (H7 → L-18); liquidation gas is ~39k/tranche so DoS needs ~750 tranches (ADMIN-only to create). Notable informationals: `IStablecoin.coverBadDebt` NatSpec promises a market-recovery route that does not exist; write-off forgives the borrower on-chain permanently; `burnCreditBacked` funded by cUSD bought from holders never raises `unlockedSupply` (queue recovery needs fresh underlying); `Oracle._read` decodes any ≥ 64-byte return so a raw-feed entry serves `roundId` as the price with a never-stale future stamp; nested oracle chains are silently priced in the wrong unit; zero-share deposits are accepted; `Underwriter.report` reverts on a removed-but-allocated tranche; `Underwriter.addTranche` checks neither asset match nor registry provenance; the same operator may be market owner and borrower; arrears on a rolled loan are priced at the cheapest point of the term curve.

---

## 5. Invariant suite

A handler-based Foundry invariant suite drives a full deployment — two floating and two fixed-market tranches, three cUSD depositors, three underwriters, borrower, liquidator, guardian, keeper — through every user-facing and privileged entry point with bounded, non-reverting calls: deposits, instant and queued redemptions and claims, borrows, repays, premium charges, liquidations, write-offs, `coverBadDebt`, fixed-loan rolls, time warps and collateral price moves in [0.5, 1.5]. Files: `audit/tests/invariants/CapHandler.sol`, `Cap.invariants.t.sol`; log: `deep-run.log`.

**Result under `[profile.deep]` — 5,000 runs × depth 200 = 1,000,000 calls per invariant, 0 reverts:**

| Invariant | Statement | Result |
|---|---|---|
| I1 | Underlying held by `Stablecoin` ≥ `unlockedSupply()` — the contract never reports redeemable supply it cannot pay | **PASS** (WS-A additionally proved equality holds algebraically through every path) |
| I2 | `totalSupply ≥ creditBackedSupply + badDebt` | **PASS** |
| I3 | `Σ market.totalDebt() == creditBackedSupply` (net of uncharged floating premium) | **PASS within dust** — the strict form is **broken** by a wei-level random walk in `FloatingMarket._premium` (L-1); the suite reproduced it (dust loan → full repay underflow) before the handler was guarded |
| I4 | `badDebt` falls only through `coverBadDebt` and `_onWithdraw` | **PASS** |
| I5 | Every unhealthy market has a remedy (`unrecoverableDebt > 0` or `maxLiquidatable > 0`) | **PASS** at defaults — **broken** by WS-B's H-2 (queued claim pushes a healthy market under `lt`), by a stale feed (M-1, reverts), and for `lt > 0.9804` (L-*) |
| I6 | Tranche weights sum to exactly 1e27 | **PASS** |
| I7 | Senior never locks more than junior | **PASS** |
| I8 | `variableCreditLimit ≤ debtLiquidationThreshold` | **PASS** at defaults — **broken** after GUARDIAN `setLt < ltv` on a floating market (L-*) |
| I9 | Tranche share price falls only through `slash` | **PASS** |
| I10 | Haircut split-equivalence | Held by WS-A fuzz (3,000 runs × 6/8/18 dp) and WS-G (7,020 cases): **0 wei** over-payment |
| I11 | Deposit→redeem round trip never profits | **PASS** |
| I12 | `IERC20(asset).balanceOf(vault) ≥ vault.totalSupply(id)` | **PASS** at rest — broken *within* a `Vault.deposit` transaction for hook tokens (L-*) |
| I13 | Shares parked in the vault == outstanding queue | **PASS** for the queue arithmetic; the second clause is violable by a direct share transfer to the vault (Info) |
| I14 | Premium conservation | Held by WS-C fuzz (3,000 runs over `PremiumVesting`) |
| I15 | FIFO — no later request claimable while an earlier one is pending | **PASS on `Stablecoin`** — **broken on `Tranche`/`Underwriter`** by WS-B's H-2; this suite only exercised the stablecoin queue, WS-B's `B_QueueInvariants.t.sol` shrinks the tranche break to six calls |
| I16 | No action against a stale index or stale Underwriter mark | **Broken** by H-1 (stale mark) and the reentrant liquidation (L-*) |

Two handler guards were added during the run and are documented in the handler: floating repays/liquidations below one scaled unit revert by design (`InvalidScaledAmount`), and the full-repay path when the floating reading sits above `creditBackedSupply` (L-1). Both were first surfaced by the fuzzer.

**New invariants the code implies that the plan did not list** (proposed by workstreams, collected here; each is the executable form of a finding):
- `Σ_open claimableRedeemRequest ≤ unlockedSupply()` for every vault (H-2).
- `Underwriter.totalDebt == Σ previewRedeem(balanceOf(t) + queuedShares[t])` at every mint/burn (H-1).
- `Tranche.totalCapital() == assets · price · 10^(18 − IOracle.DECIMALS) / 10^assetDecimals` (C-1).
- `lt · (1 + liquidationBonus) ≤ 1e27` for every market (health leads protection).
- Registry-seeded `lt/buffer/targetHealth` satisfy the markets' own setter predicates.
- Every `restricted` selector resolves to a role named in `ConfigureAccessControl`/`Registry`, never role 0 by omission.
- A fixed premium is never charged below `_nextLiquidityRate(utilizationRateAfterMint(principal))`.
- No credit-backed cUSD is minted as premium to a tranche with `totalCapital() == 0`.
- `id < loanCount` for every id-taking `FixedMarket` function.

---

## 6. Economic analysis

All eight models are in `audit/models/` (standard-library Python, shared exact-arithmetic `capmath.py` that reproduces `WadRayMath`, `Math.mulDiv`, the binomial compounding, the EMA, the haircut curve and the liquidation formulas in integer ray arithmetic). Full outputs are in `audit/models/output/` and `audit/findings/G.md`. Defaults: IRM `1e27, 2e27, 1e27, 0.02e27, 1h`; `lt 0.8 / buffer 0.1 / targetHealth 1.25`; `ltv 0.5`; slopes 5 %/5 %/10 %/kink 80 % (from the test deployer — **`DeployInfra` never sets liquidity slopes**, so a production deploy starts at a 0 % liquidity rate); underwriter rate 20 %; weights 95/5.

| Model | Question | Critical threshold |
|---|---|---|
| `solvency_waterfall.py` | Shock at which depositors first lose | At a fully-drawn line: **health < 1 at a 37.5 % correlated drop; cUSD holders lose at 49.0 %** (cushion `1 − (1+b)·lt` = 18.4 %). The first liquidation at health 1 clears **58 % of debt in one call** (`(TH−1)/(TH−(1+b)·lt)`), wipes and permanently `kill`s the 5 % junior in every scenario, and touches the senior in the same call. |
| `solvency_waterfall.py` §4 | Is `healthiness()` leading or lagging? | **Leads** by 18.4 % of price at defaults; **lags whenever `lt > 1/(1+b) = 0.9804`**, which `setLt` permits up to 1.0 — a market can report healthy while `unrecoverableDebt > 0` and `liquidate` reverts `Healthy()`. In the time dimension it lags by construction: premium accrues into debt every block with no price move. |
| `liquidation_cascade.py` | Clears or spirals? | An online, clip-sizing liquidator clears every GBM path to 300 % vol at any bonus > 0 — the system does not spiral. Loss is a **liveness** problem: offline liquidator or `bonus = 0` (permitted) gives P(loss in 30 d) **4 % at 100 % vol, 12 % at 150 %**, avg shortfall \$7–9M on \$50M; a 24 h check interval at `lt 0.95` loses 5–15 % of paths. Capital: **~\$30M cUSD at par** to restore a \$50M market from 1.0 → 1.25. |
| `rate_sweep.py` | Where is underwriting irrational? | No protocol take exists. Underwriting is **negative-EV below `underwriterRate = (1+b)·p_default` = 2.04 %** at 2 %/yr default risk (5.10 % at 5 %). The rate is set by the *borrowing side* (market owner), has **floor 0**, and responds to nothing; **71 % of tranche capital is locked at full draw** — exactly when the rational response is to leave. |
| `run_dynamics.py` | When does redemption stop being orderly? | Wait ≤ 7 d breaks at daily requests ≥ **1.12 % of supply** against 1 %/day fresh-funded repayment. Repayment with cUSD bought from holders **never raises `unlockedSupply`**. The haircut curve **does** remove the first-mover advantage for *recognised* bad debt (payout/share monotone 0.816 → 0.891) but **not** before the discretionary `writeOff` — see the recognition-lag finding. |
| `reserve_decay.py` (H1) | The "minted yield" clock | At u₀ 80 %, 30 % carry: reserve 20 % → 15.5 % after 1 y, first < 5 % after **4.5 y** (2.1 y from u₀ 90 %); only u₀ ≥ 92.9 % breaches within a year. A \$10M 30-day fixed borrow mints ~\$250k instantly. **A slow clock, not a cliff** — but nothing enforces the repayment rate that would stop it. |
| `haircut_curve.py` (H6) | Does the bad-debt curve leak? | **0 wei** over-payment across 7,020 split cases (n ≤ 1000), 0 wei round-trip gain, monotone, I1 preserved, at 6/8/18 decimals. The NatSpec's "exactly equal, not equal up to dust" claim survives; every deviation is in the vault's favour. |
| `ema_manipulation.py` (H10) | Cost of the EMA park vs discount | At u 90 %: a \$100M par deposit held one window cuts a \$10M/30 d fixed premium **\$127k → \$66k (saves \$61k)** for **\$13.7k** at the 1-day max period and **\$68** at the 5-min min. Break-even D < 0.1× supply at every period — **the band bounds duration, not profitability.** |
| `param_sensitivity.py` (H8) | Governance range ∩ unsafe range | **13 of 18** settable parameters overlap an unsafe range. Accounting-breaking: `lt ∈ (0.9804, 1]`; unbounded `base/slope0/slope1` (≥ 17,207 %/yr → liquidatable within a day; > 3.4e11 ray reverts `_index()` and bricks every floating market **and** `setLiquiditySlopes` itself); `Registry.initialize` accepting `lt ≤ buffer` / `TH < (1+b)·lt`. |

**Modelling caveat (from WS-G):** the cascade's market-impact depth and the default-probability inputs are stated assumptions in each docstring, not measured; the thresholds that depend on them (cascade, rate sweep) are structural in shape but the exact numbers move with those inputs. The solvency, haircut, EMA and parameter thresholds are pure arithmetic on the contracts' own formulas.

---

## 7. Systemic observations

Looking across the findings rather than at any one of them, the same defect recurs: **the protocol consumes numbers it does not own, and neither checks their freshness nor their scale at the boundary.**

- `Tranche` consumes an oracle price and assumes 18 decimals; the oracle produces 8 (C-1).
- `Underwriter` consumes a cached tranche valuation refreshed on a keeper cadence; redemptions price off it in between (H-1).
- `ERC7540AsyncRedeem` consumes `unlockedSupply()` as a cumulative high-water mark; on tranches that figure moves for reasons the queue never sees (H-2).
- `FixedMarket` consumes a time-weighted utilization that any par, fee-less deposit can move for one window (M-2).
- `Stablecoin` consumes `badDebt`, which is only written by a discretionary GUARDIAN action, while `unrecoverableDebt()` is already public (M-4).
- `PremiumVesting` consumes `stakedSupply()` at funding time, not over the exposure period (M-3).
- `BaseMarket` consumes `Registry`'s defaults without the validation its own setters enforce (L-*).

The second pattern is a **test suite that pins the mirror rather than the thing**: `MockOracle` declares `DECIMALS = 8` and is fed `1e18`; `RoleTable.t.sol` pins `CapDeployer`, which copies `ConfigureAccessControl`'s omission; `test_debtNeverExceedsCreditBackedSupply` runs 20 × 13 s and passes because the random walk has not crossed yet. 399 green tests did not see a Critical, a High, or the I3 break — because the doubles they run against disagree with production in exactly the places that matter.

Third, **liveness is concentrated in single privileged addresses with no fallback**: one LIQUIDATOR, one GUARDIAN for write-off, one KEEPER for `report`, one ADMIN key that is also every beacon's owner. Most of the Medium findings become High if those addresses are slow, and the models show the loss is a function of latency, not of price.

The fix is the same in each case: **enforce the contract at the boundary** — rescale and assert `DECIMALS` where a price is read; re-mark before any share-price consumer runs; cap queued payouts at live liquidity; price fixed premiums off `max(average, spot-after-mint)`; make recognition reachable by anyone bounded exactly as `_writeOff` already bounds it; validate registry defaults with the setters' own predicates; and make the test doubles fail when they disagree with the real component.

---

## Appendix A — Gas & style (unranked)

Collected from every workstream; unranked, no severity. File references are to the workstream findings for detail.

**Correctness-adjacent but not findings**
- `BaseMarket.totalDebt()` is `virtual` with an empty body rather than `abstract`; a market that forgets to override silently reads zero debt.
- `FixedMarket.extend` on a live loan panics `0x11` rather than reverting `InvalidTerm` after `setTermLimits` lowers the maximum below an open loan's remaining term.
- `_rollFromNow` computes arrears from `previousExpiry == 0` on a never-borrowed id (~55 years); harmless only because `debt[id] == 0` — see M-5.
- `Oracle._read` decodes any ≥ 64-byte return; require `== 64`, and dry-run entries in `setSource/setBackup`.
- `setChain` accepts a leg that itself has a chain (silently priced in the wrong unit) and duplicate legs (ratio squared).
- `InterestRateModel` with `kink == 0` has a discontinuity at u = 0; on a cold system `averageUtilizationAfterMint(m) = 100 %`.
- `Tranche`/`Underwriter` `_update` allows a direct share transfer to `address(this)`, stranding the shares and breaking I13's second clause.
- `supportsInterface` claims `IERC1155Queue`; there is no `queueNft()` getter; `claimableRedeemRequest` can revert (ERC-7540 says MUST NOT) on a stale junior feed.
- Declared-but-unused in `IERC7540AsyncRedeem`: `CancelRedeem`, `CancelExceedsPending`, `RedeemRequestNotFound`, `NoPendingShares`, `NoClaimableShares`, `ZeroAddress`.
- Zero-share deposits are accepted (`previewDeposit` → 0 shares, assets taken); add `if (shares == 0) revert`.
- `Stablecoin.totalAssets()` is in share units, not `asset()` units (documented; off by 1e12 for a 6-dp integrator).
- `IStablecoin.coverBadDebt` NatSpec promises a market-recovery route that does not exist.
- `Underwriter.report` reverts on a removed-but-still-allocated tranche, so its premium can never be swept.

**Gas**
- `BaseMarket.lockedValue`/`totalCapital` re-read every tranche's oracle; `_liquidate` walks the array four times (≈ 39k gas/tranche). Cache once per call. Cap tranche count in `_setTranches` (O(n²) dedupe).
- `Tranche.maxWithdraw → maxRedeem → instantUnlockedSupply → unlockedSupply` is three oracle round-trips per withdraw.
- `Stablecoin.supplies()` and `utilizationRate()` both read `totalSupply()` inside one `updateLiquidityRate`.
- `FloatingMarket.index()` duplicates `premiumIndices()`'s same-block branch.
- `MathUtils.calculateLinearInterest` is unused.

**Repo hygiene**
- `foundry.toml`: `script = "scripts"` → `"script"`; `fs_permissions` and remappings still reference Symbiotic/Eigen/LayerZero paths that no longer exist; `lib/` contains six untracked v1 submodules.
- `contracts/deploy/service/DeployInfra.sol` imports `forge-std/Vm.sol` and uses cheatcodes from inside the production source tree; `WalletUtils` checks `tx.origin`. Move `contracts/deploy/` to `script/` once F-1 is fixed.
- `DeployLibs` returns a struct with one `unused` field; `DeployInfra._deployInfra` takes an unused `delegationEpochDuration`; `VaultConfig/FeeConfig/LibsConfig` are dead.
- `TEST.md` describes `test/deploy/TestDeployer.sol` and a fork mode that no longer exist.
- `Registry._configureMarketRoles` wires seven `IFixedMarket` selectors onto floating markets and re-wires the IRM's MARKET selectors on every `createMarket`.
- `IBaseMarket.Liquidate.assetsSlashed` is a USD value; `Underwriter.Reported(gain, loss)` are mutually exclusive.
- `test/unit/cap/InterestRateModel.t.sol` never exercises the busy-regime EMA; `test/shared/mocks/MockOracle.sol` should assert the scale it declares.
