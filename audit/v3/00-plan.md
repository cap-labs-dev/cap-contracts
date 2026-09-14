# Cap v2 — Round-3 Audit Plan

Target: branch `cap-network`, commit `a843c1d` ("Fix rounding issues", 2026-09-14 16:28 +0100).
Prior rounds: round 1 at `3c45dca` (deliverables `audit/` on branch `cap-network-audit` @ `a3308e0`), round 2 at `3dad5ef` (`audit/v2/` same commit; final report text in `stash@{0}`). A read-only copy of both sits in the session scratchpad under `prior/audit/`.

## 1. Toolchain and baseline (verified)

| Item | Value |
|---|---|
| Foundry | 1.6.0-nightly (c1cdc6c, 2026-03-10) |
| solc / evm | 0.8.36 / `osaka`; optimizer on, 200 runs; default profile **no** `via_ir` (release profile has it) |
| Build | `forge build` → exit 0, 15.9 s wall |
| Tests | `forge test` → 574 passed / 0 failed / 38 suites, 0.87 s wall (3.6 s CPU). 552 `test_`, 22 `testFuzz`, **0 invariants** under `test/` |
| OZ | `@openzeppelin/contracts` and `-upgradeable` 5.7.0, pinned by `resolutions`+`overrides`; `diff -rq` against `npm pack` of 5.7.0 → **byte-identical** |
| slither | 0.10.4, repo config (`FOUNDRY_PROFILE=slither`), 99 contracts / 58 detectors / 48 results → triaged in the report appendix |
| halmos | 0.3.3 (venv) |
| Gambit | v1.0.6 macOS binary, driven with `~/.svm/0.8.36/solc-0.8.36` |
| universalmutator | installed (venv) as fallback for files Gambit cannot parse |
| Python | 3.11 + numpy 1.24, scipy 1.17, mpmath 1.4 (venv) |
| `lib/` | only `lib/forge-std` is a submodule (v1.9.4). `lib/layerzero-*`, `lib/tokenized-strategy`, `lib/openzeppelin-foundry-upgrades`, `lib/solidity-bytes-utils` are **untracked v1 leftovers**, referenced by no source file, only by the auto-generated `remappings.txt`. `foundry.toml`'s own 4-entry `remappings` array is authoritative. Excluded. |

Audit tests are run with `FOUNDRY_TEST=audit/v3/tests forge test --match-path 'audit/v3/tests/**'`; `foundry.toml` is untouched.

## 2. Scope

**In scope** (21 files, 4,427 lines):
`contracts/cap/{Registry,Stablecoin,Tranche,Underwriter,Vault,Wrapper,InterestRateModel,BeaconFactory}.sol`, `contracts/cap/market/{BaseMarket,FixedMarket,FloatingMarket}.sol`, `contracts/cap/oracle/{Oracle,ChainlinkAdapter}.sol`, `contracts/ERC7540/{ERC7540AsyncRedeem,ERC7540Operator}.sol`, `contracts/utils/{WadRayMath,MathUtils,PremiumVesting,DeadShares,AssetId,CapRoles}.sol`. Interfaces are read for documented intent.

**Verified and excluded**: OZ 5.7.0 (byte-identical); `WadRayMath` lines 1–105 and `MathUtils` are Aave v3 (diffed by WS-A; the four Cap-authored functions `rayPow`, `rayPowRay`, `rayLn`, `rayExp` are in scope).

**Light review**: `script/Deploy.s.sol`, `script/deploy/service/*`, `script/config/Users.sol` for initial role wiring; v1 `main` @ `695c828` `contracts/token/{CapToken,StakedCap}.sol` + `contracts/vault/Vault.sol` for Workstream U.

**Out**: mocks, `test/`, `broadcast/`, `coverage/`, `lcov.info` (April 2025, v1), untracked `lib/*`.

**Decisions from Matt (2026-09-14)**: deliverables in `audit/v3/`; curators and market owners are **third parties**, not protocol-trusted; full regression of every open round-1/2 finding; live mainnet cUSD `0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC` and stcUSD `0x88887bE419578051FF9F4eb6C858A951921D8888` **will be upgraded** to this code.

## 3. Delta since round 2 (`3dad5ef..a843c1d`, 4 commits, contracts +1.9k/−1.2k)

| Area | Change |
|---|---|
| `WadRayMath` | +`rayPowRay`, `rayLn`, `rayExp` (artanh / Taylor series, mixed half-up and floor rounding, no bound on `exp <<= k`); sole consumer `FloatingMarket._growIndex` |
| `FloatingMarket` | multiplier is an **exponent** on global growth (`_growIndex`); new `lastGlobalIndex` slot inserted mid-layout; `_borrowWithin` (floor) / `_repayWithin` (ceil) pair; `_premium` as difference of three valuations; `borrow` returns realised rise |
| `FixedMarket` | `_borrowPremium` incremental in global `unsmoothedCredit`; `availableCredit(term)` catch-up; `_requireLoan`/`_requireOpenLoan` (M-5 fix); `extend` guard; multiplier on liquidity leg only |
| `InterestRateModel` | multiplier storage removed; `liquidityIndex()` global; `unsmoothedCredit()`; `averageUtilizationAfterMint` adds unabsorbed credit to both sides |
| `ERC7540AsyncRedeem` | ERC-1155 receipts removed; ids from 1; `previewRedeem/Withdraw` revert; `maxRedeem` sums claimable requests; 3-arg `redeem/withdraw` = FIFO `_claimFifo` with O(n²) `_sortIds`; `transferRequest`; per-request clamp to `unlocked` |
| `Registry` | `createChildRoles(parent, members[][])` (WHITELISTED, arbitrary parent); create* KEEPER→WHITELISTED; `set{Depositor,Borrower,Allocator}Role` forwarders (PROTOCOL); `setTranches` REGISTRY-only (R2-M1 fix); beacons' `upgradeTo` → ADMIN; storage reordered |
| `Stablecoin` | `recognizeBadDebtIn{Reserve,Credit}` with `badDebt ≤ totalSupply`; `setReserveVault`; `backing()`; `totalAssets` scaled to underlying decimals; `unlockedSupply` capped by on-hand balance |
| `Tranche` | `slash` reports delivered value, floor-to-zero passes to next; `unlockedSupply` ceil×2 with oracle bypass at zero lock; `registry` slot prepended |
| `Underwriter` | `registry` prepended; `deallocate`→`instantRedeem`; NatSpec declares curator "trusted" and mark lag intentional |
| `Wrapper` | DeadShares seed (+1 cUSD seed at deploy) |
| `Vault`, `Oracle`, `PremiumVesting` | CEI reorder; `_read` exactly 64 bytes; `_update` accrues only when a side is opted-in or `staked==0` |

## 4. Trust model as derived from code (deploy + Registry wiring)

Access control is OZ `AccessManager`; the only modifier is `restricted`; role→selector wiring lives entirely in `Registry._configure*` and is applied at `Registry.initialize` (Registry holds ADMIN permanently) and at each `create*`.

| Role (id) | Holders after `script/Deploy.s.sol` | Powers (selectors) |
|---|---|---|
| ADMIN (0) | Registry **and** `users.admin` (env `ADMIN`, defaults to the broadcast wallet) | AccessManager admin: grant/revoke every role, `execute` beacon `upgradeTo` ×4, UUPS `_authorizeUpgrade` on Registry/Stablecoin/IRM/Oracle/Vault/Wrapper/BeaconFactory (whatever role those selectors resolve to — WS-E confirms none default to 0 by omission) |
| GUARDIAN (1) | env `GUARDIAN` (default broadcast wallet) | `Stablecoin.recognizeBadDebtInReserve`; market `setBuffer`, `setLt`, `writeOff` (floating & fixed) |
| GOVERNOR (2) | env `GOVERNOR` | `Stablecoin.setReserveVault`; IRM slopes/term multiplier/liquidation bonus/averaging period; `Oracle.setSource`; market `setTargetHealth`, `setFixedCreditLimit`, `setTermLimits` |
| KEEPER (3) | env `KEEPER` | `Stablecoin.invest`/`recall` (uncapped); `FixedMarket.extendAdmin`; `Underwriter.report` |
| MARKET (4) | every deployed market | `Stablecoin.mintCreditBacked/burnCreditBacked/recognizeBadDebtInCredit/fundCreditBacked`; `IRM.updateUnderwriterRate`; `Tranche.fund` |
| REGISTRY (5) | Registry | `BeaconFactory.create`; `BaseMarket.setTranches` |
| LIQUIDATOR (6) | env `LIQUIDATOR` | `liquidate` on both market types (liquidation is **permissioned**) |
| WHITELISTED (7) | **nobody by script** — granted later by ADMIN | `Registry.createChildRoles/createFloatingMarket/createFixedMarket/createUnderwriter` |
| PROTOCOL (8) | every market, tranche, underwriter | `Registry.set{Depositor,Borrower,Allocator}Role` (keyed on `msg.sender`) |
| operator roles (≥100) | created by WHITELISTED via `createChildRoles` (admin = any `parentRoleId`) or per-tranche by `_deployTranche` | market owner: `setTrancheWeights`, `setLtv`, `setMarketMultiplier`, `extend`, `setUnderwriterRate`, `setBorrowerRole`, `setDepositorRole`, `Tranche.setDepositorRole`, `Registry.createTranche` (inline `hasRole`); curator: `Underwriter.addTranche/removeTranche/setDepositorRole/setAllocatorRole`; allocator: `allocate/deallocate/deallocateAsync/finalizeDeallocateAsync/setDefaultTranche`; borrower: `borrow/borrowMore/extend`; depositor: `deposit/mint` |
| PUBLIC | anyone | `Vault.deposit/withdraw/transfer/transferFrom` (own balance); `Stablecoin.deposit/mint/fund/coverBadDebt` + all ERC-7540 request/claim/transferRequest; `PremiumVesting.optIn/optOut/claim`; `FloatingMarket.repay/chargePremium`; `FixedMarket.repay`; `IRM.updateLiquidityRate`; `Wrapper.*` |

Deviations from the documented model (there is no README/docs trust model; the only prose is NatSpec and `config/README.md`):
- `IUnderwriter` NatSpec: "curator role is expected to be held by a timelock or secure multisig … trusted to name a real protocol tranche". Code: any WHITELISTED address mints a curator role for itself and `addTranche(arbitrary)` grants full ERC-6909 operator rights over the underwriter's vault balances. Per Matt, curators are third parties → this is a trust gap, not an assumption.
- `config/README.md` says mainnet cUSD/stcUSD are existing proxies; `Deploy.s.sol` deploys fresh CREATE3 proxies and overwrites the config. Matt: live proxies will be upgraded → WS-U.
- "Underwriters … participate through restaking networks (Symbiotic, EigenLayer)" (audit brief): **no restaking code exists in `contracts/`**. Collateral is plain ERC-6909 balances in `Vault`. The correlation premise from the brief is reported as not applicable to the contracts, and modelled economically only.
- Liquidation is LIQUIDATOR-only; write-off is GUARDIAN-only; underwriter marks refresh only on allocator/keeper action; reserve-loss recognition is GUARDIAN-only. The protocol's safety depends on the latency of four privileged addresses.

## 5. Invariants

Carried from rounds 1–2 (statements as in `prior/audit/00-plan.md` and `prior/audit/v2/00-plan.md`): I1–I24, plus I25 (every Vault operator granted by an Underwriter is a Registry-deployed tranche), I26 (`redeem(maxRedeem(a))` never reverts), I27 (ordered list of tranches with capital invariant under `setTranches` while debt outstanding).

Round-3 additions (H = handler invariant, F = property fuzz, D = differential test, S = static table, P = Python model):
- **I28 (F+P)** For `b ≥ RAY`: `rayPowRay(b,e) ≥ RAY`, and `≥ b` when `e ≥ RAY`. Monotonicity within a stated ulp tolerance. `exp <<= k` overflow bound stated.
- **I29 (D)** `_growIndex` split error is directional (floor in `rayExp` ⇒ more splits accrue less) with a numeric bound.
- **I30 (H, master)** After `chargePremium()` on every floating market: `Σ_m totalDebt_m == creditBackedSupply` (±markets wei); always `creditBackedSupply ≥ Σ_m debt-at-last-charge`. Coverage ratio `Σ totalCapital·lt / Σ totalDebt` recorded as a ghost.
- **I31 (F)** `_borrowWithin`/`_repayWithin` shortfall `≤ idx/RAY + 1`; liveness corollary documented.
- **I32 (F)** `principal ≤ availableCredit(term)` ⇒ `borrow` succeeds, `healthiness ≥ 1e27`, `totalDebt ≤ creditLimit`; split-invariance of the premium.
- **I33 (H)** `Σ_ids requestShares[id] == redeemQueue − settledQueue`; `balanceOf(this) == redemptionQueue()` on Tranche/Underwriter; `controllerRequests[c] == {id : requestController[id] == c}`.
- **I34 (H)** `cUSD.balanceOf(stablecoin) ≥ redemptionQueue() + remaining()`.
- **I35 (H)** `creditBackedSupply + badDebt ≤ totalSupply`.
- **I36 (F, 6-dec and 18-dec)** `_convertToAssets`/`_convertToShares` inverses within 1 asset-wei (= 1e12 share-wei at 6 dec) across the shortfall domain; round trip never profits.
- **I37 (H)** `Underwriter.totalAssets() ≥ live valuation`; equality after `report` on every registered tranche.
- **I38 (H)** `lt·(1 + liquidationBonus) ≤ 1e27` ⇔ `unrecoverableDebt() > 0 ⇒ healthiness() < 1e27`.
- **I39 (H)** Killed tranche with dust capital and staked supply still takes full premium weight (expected to hold; reported if so).
- **I40 (S)** Role table: every selector on every instance resolves to the role named in `_configure*`, none to 0 by omission.
- **Un-writable, stated**: `Stablecoin.totalAssets()` vs USDC on hand plus Aera has no on-chain invariant.

## 6. Attack hypotheses (owner in brackets)

P1 [C] Curator drains Underwriter via `addTranche(arbitrary)` (R2-H1 regression; High).
P2 [B] Dust `requestRedeem` + reverse-order `transferRequest` floods a controller; `_claimableShares` re-runs `unlockedSupply()` (oracle walk) per id ⇒ 3-arg `redeem/withdraw/maxRedeem` OOG. Gas at n = 50/200/500.
P3 [B] Out-of-order settlement over-credits earlier requests (H-2 regression) under the per-request clamp.
P4 [C] Underwriter stale mark, exit (H-1) **and entry** (`deposit` prices on stale `totalDebt` before `_allocate→_mark`).
P5 [A] `rayPowRay` error makes floating debt accrue less than `multiplier×` or fall; `_premium` underflow if the underwriter index could decrease.
P6 [lead] Fixed `_borrowPremium` uses global `unsmoothedCredit`: same-block floating borrow+repay pays nothing while a fixed borrower pays `C·term·Δrate`; M-2 regression.
P7 [G] No expiry enforcement beyond keeper `extendAdmin`; one defaulter's `Unhealthy` blocks every borrower's `extend`.
P8 [lead] Borrower opts in on cUSD and captures `D/(D+staked)` of every `fundCreditBacked`.
P9 [D] Permissionless `chargePremium()`/`extendAdmin` on a market with `unrecoverableDebt > 0` keeps minting unbacked premium to stakers until GUARDIAN writes off.
P10 [D] Waterfall dust: `slash` floors to zero and passes on ⇒ `slashed < repaid×(1+bonus)`; profitability sweep.
P11 [D] One dead feed on a funded tranche reverts `totalCapital` ⇒ health, liquidation, write-off, borrow, senior `unlockedSupply` all revert (M-1 regression).
P12 [E] Front-running `writeOff`/`recognizeBadDebtInReserve` with par `instantRedeem`; R2-H2 regression.
P13 [D] For `lt ≥ 1/(1+b)` GUARDIAN can write off while `liquidate` reverts `Healthy()` (I38).
P14 [lead] Headline composition: one WHITELISTED address → `createChildRoles` → market → `createTranche(any priced asset)` → own depositor role → `setLtv` → `setBorrowerRole(self)` → borrow against a thin junior; only `fixedCreditLimit` throttles; junior also unlocks seniors.
P15 [E] `createChildRoles` arbitrary parent; `setDepositorRole` lacks `PublicRole`/`isOperatorRole` guards; `createTranche` ignores execution delay; `setBorrowerRole` accepts another owner's role.
P16 [E] Registry `_authorizeUpgrade` target role; beacon ownership; deploy defaults put every role on one EOA.
P17 [C] `removeTranche` strands premium (`_report` requires registration and is the only `claim` caller).
P18 [C] Opt-in forfeiture; senior with `stakedSupply==0` redirects underwriter premium to cUSD holders.
P19 [B] Hook-token reentrancy mid-waterfall in `Tranche.slash`; read-only reentrancy across markets.
P20 [B] `Vault.deposit` mints `_amount` not received; `Oracle._read` decode; primary→secondary discontinuity.
P21 [E] Dead `deposit/mint` selectors wired on markets; unreachable `IncompleteClaim` outer checks (style).
P22 [U] Live-proxy upgrade: `Initializable` at version 1 ⇒ `underlyingDecimals/irm/reserveVault` unset; v1 namespaces; live supply not on hand ⇒ `unlockedSupply()==0`; `Wrapper.initialize`'s `optIn` never runs; migration order.
Closed in planning: `maxLiquidatable` underflow (`perCleared ≥ 0.15e27` at deploy bounds: `targetHealth ≥ 1.25`, `lt ≤ 1`, bonus `≤ 0.1`).

## 7. Workstreams and ownership

| WS | Owner | Scope (hypotheses / invariants) | Output |
|---|---|---|---|
| A Math | subagent | rounding table for every division; `_borrowPremium`/`_principalWithin`/`_premium`; 6-dec haircut curve (I36); P5; I28/I29 via exact-integer Python vs `mpmath`; halmos on single-op functions only | `findings/A.md`, `tests/scratch/A/`, `models/wadray_check.py` |
| B External callers | subagent | P2, P3, P19, P20; permissionless sweep; I33 | `findings/B.md`, `tests/scratch/B/` |
| C Coverage & collateral | subagent | P1, P4, P17, P18; `lockedValue`/`unlockedSupply` derivation; I25/I27/I37 | `findings/C.md`, `tests/scratch/C/` |
| D Liquidations & oracles | subagent | P9, P10, P11, P13; profitability sweep; LIQUIDATOR liveness; L2 assumptions | `findings/D.md`, `tests/scratch/D/` |
| E Mint/redeem, access, upgrades | subagent | P12, P15, P16, P21; I40 role table vs `RoleTable.t.sol`; initializers; ERC-7201 slots; deploy wiring | `findings/E.md`, `tests/scratch/E/` |
| U Upgrade compatibility | subagent | P22; storage-layout diff v1→v3 for cUSD and stcUSD; `Initializable` state; migration order | `findings/U.md` |
| F Test suite & mutation | subagent | §4 of the brief; Gambit + universalmutator + hand-authored mutants; killing tests | `test-suite-assessment.md`, `tests/mutants/` |
| G Economic models | subagent | solvency, coverage lag, cascades (P7, P9), rate sweep (P6, P8 numbers), run dynamics (P12), parameter sensitivity | `models/*.py`, `models/README.md`, `models/output/` |
| R Regression | subagent | port and re-run all round-1/2 open findings | `findings/REGRESSION.md`, `tests/scratch/R1/`, `tests/scratch/R2/` |
| Lead | — | trust model (§4) and P14 with PoC; I30 and the invariant suite (`tests/invariants/`, deep run); P6/P8 rate economics | `cap-v2-audit-report-r3.md` |

Verification (Phase 3): a fresh subagent per round-3-new Critical/High/Medium, given code and finding text only, tasked to disprove; verdicts under `findings/verify/`.
