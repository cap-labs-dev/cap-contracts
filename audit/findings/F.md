# WS-F — Access control, upgradeability & storage, Registry, deploy wiring, code safety

Scope read end to end: `Registry.sol`, `BeaconFactory.sol`, `Vault.sol`, `CapRoles.sol`, `AssetId.sol`,
`IRegistry.sol`, `IBeaconFactory.sol`, `IVault.sol`, all of `contracts/deploy/**`, `test/shared/CapDeployer.sol`,
`test/integration/RoleTable.t.sol`, `script/DeployInfra.s.sol`, `script/config/WalletUsersConfig.sol`.
Skimmed for `restricted`, external calls, `_authorizeUpgrade`, storage, loops and `initialize`: every other
contract in `contracts/cap/`, `contracts/ERC7540/`, `contracts/utils/`.

Tests: `audit/tests/scratch/F/` — run with
`FOUNDRY_TEST=audit/tests forge test --match-path 'audit/tests/scratch/F/*' -vv`. The broadcast simulation is
`forge script audit/tests/scratch/F/F6_ProdDeployBroadcast.s.sol --sender 0x1000000000000000000000000000000000000001`.

Severity count: **0 Critical, 0 High, 0 Medium, 4 Low, 9 Informational.** Nothing in this workstream moves
depositor funds without a corresponding accounting update from an *unprivileged* position. The two things
that matter most are (a) the production deployment path does not work at all, so whatever gets deployed will
be deployed by hand, outside the wiring that was reviewed, and (b) the protocol has no timelock anywhere and
its four beacons sit outside the AccessManager entirely.

---

## Findings

### [LOW] F-1 The production deploy path is broken three ways, and `forge build` cannot see it
**Location:** `script/DeployInfra.s.sol:21-52`, `script/config/WalletUsersConfig.sol:11-23`,
`contracts/deploy/service/DeployInfra.sol:44-46` (`_deployInfra`), `foundry.toml:7` (`script = "scripts"`)
**Impact:** The only deployment entrypoint that inherits `contracts/deploy/**` cannot deploy the protocol:
1. `WalletUsersConfig._getUsersConfig` builds `UsersConfig` with 8 fields; the struct has 9 (`oracle` was added
   to `DeployConfigs.sol` but not to the script). **It does not compile.**
2. Even with (1) fixed, `DeployInfra._deployInfra` computes the IRM/Stablecoin circular addresses from
   `VM.getNonce(address(this))` / `computeCreateAddress(address(this), n)`. Under `vm.startBroadcast()` the
   CREATEs are attributed to the broadcaster, and forge refuses the pattern outright:
   `Usage of address(this) detected in script contract`. **The script reverts after the Vault proxy.**
3. `foundry.toml` sets `script = "scripts"` (directory does not exist; the real one is `script/`). `forge build`
   therefore never compiles `script/`, so neither (1) nor the stale v1 scripts around it fail CI.
Secondary effects of the same file: `stakedStablecoin` defaults to the deployer **EOA**
(`VM.envOr("STAKED_STABLECOIN", wallet)`) — every liquidity premium the protocol mints (`BaseMarket._chargePremium`,
`stakedStablecoin` branch) would go to that EOA; every role (admin, governor, keeper, guardian, liquidator,
beacon owner) is the single broadcasting wallet; and **no Oracle is deployed or wired anywhere in
`contracts/deploy/**`** — `users.oracle` is an input and `script/DeployTestnetVault.s.sol` imports a
`contracts/deploy/service/ConfigureOracle.sol` that does not exist. Consequently `Oracle.setSource/setBackup/setChain`
have no role wired and resolve to ADMIN (role 0) on any Oracle sharing the AccessManager (F1 test,
`test_F1_oracleSettersResolveToAdminAndGovernorIsLockedOut` — passes, documents).
**Likelihood:** Certain on the next deployment attempt. No attacker involved; the risk is that mainnet is wired by
hand, outside the code that was reviewed, with a premium sink and role holders nobody chose deliberately.
**Exploit path:** n/a (operational). Dollars at risk: not estimable; all lender yield to an EOA if deployed
with defaults.
**Proof:**
```
$ forge build script/DeployInfra.s.sol
Error (9755): Wrong argument count for struct constructor: 8 arguments given but expected 9.
  --> script/config/WalletUsersConfig.sol:13:17:

$ forge script audit/tests/scratch/F/F6_ProdDeployBroadcast.s.sol --sender 0x1000...0001 -vvv
    ├─ [105520] → new ERC1967Proxy@0x2AB44B89e1Ef62b3ae7B0c6bd50688311dFfae13   (Vault proxy)
    └─ ← [Revert] Usage of `address(this)` detected in script contract. Script contracts are ephemeral and their addresses should not be relied upon.
Error: script failed: Usage of `address(this)` detected in script contract.
```
**Recommendation:** Fix `foundry.toml` to `script = "script"` so `forge build` compiles the scripts. Add `oracle`
to `WalletUsersConfig` (and stop defaulting `stakedStablecoin` to the wallet — require the env var). Replace the
`address(this)` nonce math with `msg.sender`-based `computeCreateAddress` under broadcast, or better, drop the
circular pre-computation: deploy the IRM proxy, deploy the Stablecoin proxy pointing at it, then set the IRM's
stablecoin through a one-shot setter (it has none today). Add an `Oracle` deploy + `ConfigureOracle` step that
wires `setSource/setBackup/setChain` to an explicit role. Delete the v1 scripts that no longer compile.
**Invariant broken:** none (pre-deployment).

---

### [LOW] F-2 (H9 confirmed) `InterestRateModel.setAveragingPeriod` is wired to nothing and falls to ADMIN; the test suite mirrors the omission
**Location:** `contracts/deploy/service/ConfigureAccessControl.sol:59-64`, `test/shared/CapDeployer.sol:270-274`,
`test/integration/RoleTable.t.sol` (claims "Covers all 49 gated selectors")
**Impact:** The four IRM policy setters are one family (`setLiquiditySlopes`, `setTermMultiplierSlope`,
`setLiquidationBonus`, `setAveragingPeriod`), documented together in `IInterestRateModel`; three are GOVERNOR,
the fourth resolves to role 0 = ADMIN because the array is sized 3. Direction is fail-*closed* — GOVERNOR is
locked out, ADMIN (a superset) can still call it — so no funds move. The real cost is that the role table is
not what anyone reading `ConfigureAccessControl` believes, and the pinning test cannot catch it: `RoleTable.t.sol`
runs against `CapDeployer`, a hand-copied mirror of `ConfigureAccessControl` with the identical omission, and it
never imports `contracts/deploy/**`. It also does not list `setAveragingPeriod`, any `upgradeToAndCall`, or the
Oracle setters, so "49 gated selectors" is 10 short of the 61 that exist. **It pins the test deployer, not
production.**
**Likelihood:** Certain (it is the deployed state). No attacker.
**Proof:** `audit/tests/scratch/F/F1_ProdRoleTable.t.sol` — deploys through `DeployImplems + DeployInfra +
ConfigureAccessControl` (the exact contracts `script/DeployInfra.s.sol` inherits), not through `CapDeployer`.
```
[FAIL: setAveragingPeriod falls to ADMIN (role 0) by omission: 0 != 2] test_F1_setAveragingPeriod_isWiredToGovernorLikeTheOtherIrmSetters()
[FAIL: AccessManagedUnauthorized(0xcF9fE13F74B6C933636EdFbB150892f53A73545b)] test_F1_governorCanSetAveragingPeriod()
  IRM.setLiquiditySlopes -> role 2
  IRM.setTermMultiplierSlope -> role 2
  IRM.setLiquidationBonus -> role 2
  IRM.setAveragingPeriod -> role 0
```
**Recommendation:** `new bytes4[](4)` with `setAveragingPeriod` in `ConfigureAccessControl` (and `CapDeployer`).
Make `RoleTable.t.sol` deploy through the production contracts (the F1 harness shows how: inherit the four
deploy services from a `Test`), and enumerate selectors from the interfaces rather than by hand so a new
`restricted` function fails the test until it is argued for. Second-order: none.
**Invariant broken:** none.

---

### [LOW] F-3 `Registry.initialize` stores `lt`/`buffer`/`targetHealth` unvalidated, has no setter, and every market inherits them verbatim
**Location:** `contracts/cap/Registry.sol:102-124` (`initialize`), `contracts/cap/market/BaseMarket.sol:44-56`
(`__BaseMarket_init`), vs. the setter guards at `BaseMarket.sol:59-107`
**Impact:** `BaseMarket.setLt` requires `lt <= 1e27 && lt > buffer`; `setBuffer` requires `buffer < lt`;
`setTargetHealth` requires `>= 1.25e27`; `maxLiquidatable` additionally relies on
`targetHealth > (1 + bonus) * lt`. None of this is checked when the Registry stores the defaults, and there is no
`setDefaults` afterwards — the values are frozen at deploy for the life of the proxy. A market created with
`lt == buffer` accepts deposits and lets the borrower draw, but `lockedValue` divides by `lt - buffer == 0`
(`WadRayMath.rayDiv` reverts on zero), so `Tranche.unlockedSupply`, `maxRedeem`, `redeem`, `requestRedeem` claims
and `Underwriter.deallocate*` all revert until a GUARDIAN calls `setLt`. A market created with
`targetHealth < (1 + bonus) * lt` becomes unhealthy on a price move and **cannot be liquidated** (`maxLiquidatable`
underflows) until GOVERNOR calls `setTargetHealth`; during that window `unrecoverableDebt` grows and the only
lever left is `writeOff`.
**Likelihood:** Requires a deploy-time mistake (the hardcoded values in `DeployInfra.sol:89-91` are sane). Given
F-1 — mainnet will be wired by hand — the chance of the constants being retyped is not negligible. Recoverable
per market by GUARDIAN/GOVERNOR once noticed.
**Exploit path:** none (misconfiguration). Cost to depositors: locked capital and un-liquidatable debt for the
detection window.
**Proof:** `audit/tests/scratch/F/F2_RegistryDefaults.t.sol`
```
[FAIL: next call did not revert as expected] test_F2_registryRejectsLtEqualBuffer()
[FAIL: EvmError: Revert] test_F2_marketWithLtEqualBuffer_depositorCanRedeem()          <- redeem reverts, deposit worked
[FAIL: panic: arithmetic underflow or overflow (0x11)] test_F2_marketWithLowTargetHealth_isLiquidatable()  <- liquidate reverts on an unhealthy market
```
**Recommendation:** Validate in `Registry.initialize` with the same predicates the setters use
(`lt <= 1e27`, `lt > buffer`, `targetHealth >= 1.25e27`), and add a GOVERNOR-gated `setDefaults` so the values
are not frozen. Better: have `__BaseMarket_init` call the internal `_setLt/_setBuffer/_setTargetHealth` so a
market can never be born in a state its own setters would refuse.
**Invariant broken:** I5 (market unhealthy with `maxLiquidatable()` reverting rather than `> 0`).

---

### [LOW] F-4 `FloatingMarket.liquidate` stores `scaledDebt` after the slash loop's external calls; a re-entrant liquidation is silently overwritten and breaks I3
**Location:** `contracts/cap/market/FloatingMarket.sol:91-105` (`liquidate`), `BaseMarket.sol:318-338`
(`_liquidate` slash loop), `Tranche.sol:93` (`IVault.withdraw` → `safeTransfer(recipient)`)
**Impact:** `liquidate` computes `(remainingScaled, cleared) = _floorReduction(debt, …)` from the
pre-liquidation debt, calls `_liquidate` (burns the liquidator's cUSD, then loops `Tranche.slash` →
`Vault.withdraw` → ERC-20 transfer to the caller-supplied `recipient`), and only then writes
`scaledDebt = remainingScaled`. If the collateral token calls the recipient on receipt (ERC-777 `tokensReceived`,
or any token with a receiver hook), the recipient can call `liquidate` again while `scaledDebt` still reads
the original debt and `totalCapital` is already lower. The inner call burns a second `R2` of cUSD, slashes
`R2·(1+bonus)` more collateral and stores `scaledDebt = D − R2`; the outer call then stores `D − R1` on top of it.
End state: `R1 + R2` cUSD burned (`creditBackedSupply` down by `R1 + R2`), market debt down by only `R1`,
`(R1 + R2)(1 + b)` of collateral gone. **I3 is broken** (`Σ totalDebt ≠ creditBackedSupply`). Downstream: the
borrower cannot repay in full (`burnCreditBacked` underflows), `R2` of phantom debt stays on the tranches and
keeps `lockedValue` high, and `Stablecoin.unlockedSupply()` (= `supply − creditBacked − badDebt`) is overstated
by `R2`, i.e. the reserve gate reports `R2` more redeemable than is backed (pressure on I1).
`FixedMarket.liquidate` is *not* affected: it does `debt[id] -= repaid` after the call, which composes.
**Likelihood:** Two preconditions, both privileged/policy: the caller holds LIQUIDATOR, and the tranche asset has
a receiver hook. `IVault.sol:9-13` excludes fee-on-transfer and rebasing tokens by policy but says nothing about
hook tokens. Cost to the liquidator: zero beyond the cUSD it would burn anyway (it receives `1 + b` per unit
both times). Motive: griefing, or a liquidator colluding with a borrower (the borrower's `R2` of paid debt is
never credited).
**Exploit path (from `F3_ReentrantLiquidate.t.sol`):** tranche0 950, tranche1 50 of hook token at $1; borrower
draws 500 cUSD; price → $0.50 (capital 500, LT 400 < 500). Liquidator contract calls `liquidate(self, 100)`. The
junior slash pays it 50 tokens → hook → inner `liquidate(self, 100)` → burns 100 more, slashes 102 more from
tranche0, stores `scaledDebt = 400`. Outer continues, slashes the remaining 77, stores `scaledDebt = 400`.
Net: 200 cUSD burned, 408 tokens (204 USD) received, `totalDebt = 400`, `creditBackedSupply = 300`.
**Proof:**
```
[FAIL: I3: market debt must equal credit-backed supply: 400000000000000000000 != 300000000000000000000] test_F3_reentrantLiquidate_breaksI3()
  cUSD burned by liquidator      : 200000000000000000000
  collateral received (tokens)   : 408000000000000000000
  market.totalDebt()             : 400000000000000000000
  stablecoin.creditBackedSupply(): 300000000000000000000
[PASS] test_F3_afterReentrancy_borrowerCannotRepayInFull()   (repay(max) reverts: burnCreditBacked underflow)
```
**Recommendation:** Store `scaledDebt` before the external calls (compute `remainingScaled`, write it, then
`_liquidate`; `_liquidate`'s health/cap checks can take the pre-reduction `debt` as an argument instead of
re-reading `totalDebt()`), or add a `nonReentrant` guard on `borrow/repay/liquidate/writeOff/chargePremium`.
There is no `ReentrancyGuard` anywhere in the codebase; the markets, `Tranche`, `Underwriter` and `Vault` all
rely on ordering alone. Second-order: none.
**Invariant broken:** I3; I16 (inner liquidation acts on a debt figure the outer call has already reduced).

---

## Informational

**F-I1 — No timelock anywhere; the four beacons are outside the AccessManager.** Production grants every role
with `executionDelay = 0` and no target has an admin delay (`test_F1_noDelaysAnywhere` passes). The six UUPS
`_authorizeUpgrade`s are `restricted` → role 0 = ADMIN (fine, and consistent with `CapRoles.ADMIN`'s doc), but
`UpgradeableBeacon` for markets, tranches and underwriters is `Ownable(users.admin)` (`DeployInfra.sol:66-69`) —
`upgradeTo` is instant, un-schedulable, and invisible to `AccessManager.canCall`. A single key (the deploy
wallet, per `WalletUsersConfig`) can replace the code behind every tranche and walk the Vault. Recommendation:
give the beacons to the AccessManager (or a timelock) and put an admin delay on `upgradeToAndCall` targets.

**F-I2 — H7: `Vault.deposit` mints before it pulls; could not be turned into a loss.** Modelled an ERC-777
`tokensToSend` hook (`F3_…::test_F3_vaultDepositMintBeforeTransfer_noProfit`, passes): mid-flight the depositor
holds 100e18 of unpaid ERC-6909 and can `withdraw` other depositors' tokens, but the outer `safeTransferFrom`
then pulls the same amount back; I12 holds after the call and the attacker's net is zero. Nothing else in the
protocol reads the depositor's *own* ERC-6909 balance during the window. Still, flip the order
(`safeTransferFrom` then `_mint`) — it costs nothing and removes the only CEI inversion on a permissionless path.

**F-I3 — `Underwriter.addTranche` checks neither `asset()` nor registry provenance.** ADMIN-only, and `_allocate`
into a tranche of another asset reverts on the ERC-6909 `transferFrom` (the underwriter holds none), so it is
inert unless someone donates that asset to the underwriter through `Vault.transfer`; then `_mark` books the
other asset's units into `totalDebt`, which `totalAssets` adds in the vault's own units. Add
`ITranche(t).asset() == asset()` and `IRegistry.isTranche` (does not exist; `isMarket` does).

**F-I4 — `Registry.createUnderwriter` does not require the asset to be priceable** (unlike `_deployTranche`).
Consequence is nil: the underwriter can only ever allocate into tranches, which are priced. A rebasing or
fee-on-transfer asset breaks I12 for that underwriter's idle balance; policy-only, as `IVault` says. Given KEEPER
creates markets, consider a GOVERNOR-maintained allowlist in `Registry` rather than an off-chain listing process.

**F-I5 — `Registry._configureMarketRoles` re-wires the IRM's MARKET selectors on every `createMarket`.** Any
ADMIN repoint of `updateUnderwriterRate/updateMarketMultiplier` is silently reverted by the next KEEPER
deployment. Wire once in `ConfigureAccessControl`.

**F-I6 — Same operator may be market owner and borrower.** `_createMarket` accepts `_marketOwner == _borrower`;
that account then sets its own `ltv` (up to `lt − buffer`), `underwriterRate` (down to 0) and tranche weights,
and admits the tranche depositors. Underwriters are protected only by GUARDIAN's `lt/buffer` and GOVERNOR's
`targetHealth/fixedCreditLimit`. Worth stating in the docs; the code does not forbid it.

**F-I7 — Upgrade-safety of inline library structs.** `PremiumVesting.Schedule` is embedded by value in `Tranche`
(slot base+4..+10, followed by `_storedPremiumBalance` at +11) and `Underwriter` (base+2..+8, followed by
`defaultTranche`, `debt`, `totalDebt`, …). Appending a field to `Schedule` shifts every later variable in both
contracts. Same for `IInterestRateModel.Slopes/RateData/UtilizationAverage` inside `InterestRateModel`. Either
freeze those structs, or move them behind their own `erc7201` namespace. No `__gap` exists anywhere; with
`layout at` and ERC-7201 structs that is acceptable *except* for these inline structs.

**F-I8 — `DeployInfra.sol` imports `forge-std/Vm.sol` and uses cheatcodes from inside `contracts/`.** It is
compiled into `out/` but is never deployed (it is `abstract`-in-practice: inherited by scripts only) and does
not leak into any deployed bytecode. It is nonetheless an on-chain no-op contract with a hardcoded cheatcode
address sitting in the production source tree. Move `contracts/deploy/` to `script/` once F-1 is fixed.

**F-I9 — Read-only reentrancy surface.** During the slash loop (`_liquidate`) every view that a
hook-recipient could call is inconsistent: `totalDebt()` unchanged, `totalCapital()` already reduced,
`Underwriter._mark`'s `previewRedeem` on the slashed tranche already lower. Only the liquidator's recipient
gets the callback, so this reduces to F-4; noted so the fix there is checked against these views too.

---

## Trust model (derived from code)

### Complete production role table

Produced by `test_F1_printProductionRoleTable` deploying through `contracts/deploy/**` (roles: 0 ADMIN,
1 GUARDIAN, 2 GOVERNOR, 3 KEEPER, 4 MINTER, 5 REGISTRY, 6 MARKET, 7 LIQUIDATOR, ≥100 per-instance operator /
depositor roles). "Wired by" is the code that sets it; **bold** = reaches role 0 by *omission*.

| Target | Selector | Role | Wired by |
|---|---|---|---|
| Registry | `assignOperator` | GOVERNOR | ConfigureAccessControl |
| Registry | `createMarket`, `createFixedMarket`, `createUnderwriter` | KEEPER | ConfigureAccessControl |
| Registry | `createTranche` | ADMIN (explicit) | ConfigureAccessControl |
| Registry | `upgradeToAndCall` | ADMIN (default) | — |
| BeaconFactory | `create` | REGISTRY | ConfigureAccessControl |
| BeaconFactory | `upgradeToAndCall` | ADMIN (default) | — |
| Vault | `upgradeToAndCall` | ADMIN (default) | — |
| Vault | `deposit`, `withdraw`, `transfer*`, `setOperator` | public | — |
| Stablecoin | `mintCreditBacked`, `burnCreditBacked`, `recognizeBadDebt` | MINTER | ConfigureAccessControl |
| Stablecoin | `coverBadDebt` | GOVERNOR | ConfigureAccessControl |
| Stablecoin | `upgradeToAndCall` | ADMIN (default) | — |
| Stablecoin | `deposit/mint/redeem/withdraw/requestRedeem` | public | — |
| IRM | `setLiquiditySlopes`, `setTermMultiplierSlope`, `setLiquidationBonus` | GOVERNOR | ConfigureAccessControl |
| IRM | **`setAveragingPeriod`** | **0 by omission** | — (F-2) |
| IRM | `updateUnderwriterRate`, `updateMarketMultiplier` | MARKET | Registry (on every createMarket) |
| IRM | `updateLiquidityRate` | public | — |
| IRM | `upgradeToAndCall` | ADMIN (default) | — |
| Oracle | **`setSource`, `setBackup`, `setChain`** | **0 by omission** | — (never deployed/wired; F-1) |
| Oracle | `upgradeToAndCall` | ADMIN (default) | — |
| Market | `setLtv`, `setTrancheWeights`, `setMarketMultiplier`, `setUnderwriterRate`, `extend` (fixed) | owner operator role | Registry |
| Market | `borrow` (floating), `borrow`/`borrowMore` (fixed) | borrower operator role | Registry |
| Market | `setTargetHealth`, `setFixedCreditLimit`, `setTermLimits` (fixed) | GOVERNOR | Registry |
| Market | `setBuffer`, `setLt`, `writeOff` | GUARDIAN | Registry |
| Market | `setTranches`, `setStakedStablecoin` | ADMIN (explicit) | Registry |
| Market | `extendAdmin` (fixed) | KEEPER | Registry |
| Market | `liquidate` | LIQUIDATOR | Registry |
| Market | `repay`, `chargePremium` (floating) | public | — |
| Tranche | `setVestingPeriod` | owner operator role | Registry |
| Tranche | `slash` (+ `msg.sender == market`), `notifyPremium` | MARKET | Registry |
| Tranche | `deposit`, `mint` | per-tranche depositor role (admin = owner role) | Registry |
| Tranche | `redeem`, `withdraw`, `requestRedeem`, `claim`, transfers | public | — |
| Underwriter | `allocate`, `deallocate`, `deallocateAsync`, `finalizeDeallocateAsync`, `setDefaultTranche`, `setVestingPeriod` | curator operator role | Registry |
| Underwriter | `report` | KEEPER | Registry |
| Underwriter | `addTranche`, `removeTranche` | ADMIN (explicit) | Registry |
| Underwriter | `deposit`, `mint` | per-underwriter depositor role (admin = curator role) | Registry |
| Underwriter | `redeem`, `withdraw`, `requestRedeem`, `claim` | public | — |
| 4 × UpgradeableBeacon | `upgradeTo` | `Ownable(users.admin)` — **outside AccessManager** | DeployInfra |
| ERC1155Queue (×N) | `mint`, `burn` | `Ownable(vault proxy)` | ERC7540AsyncRedeem init |

Role membership in production: `users.admin` ADMIN; **Registry ADMIN + REGISTRY**; governor GOVERNOR; keeper KEEPER;
guardian GUARDIAN; liquidator LIQUIDATOR; every market MINTER + MARKET; operators get their role at first
`createMarket/createUnderwriter`. Every grant has delay 0. Role admins: operator roles → REGISTRY; each depositor
role → its owner/curator role; everything else → ADMIN.

Role-0 selectors, total 15: 5 explicit (`createTranche`, `setTranches`, `setStakedStablecoin`, `addTranche`,
`removeTranche`), 6 `upgradeToAndCall` (intended per `CapRoles.ADMIN` doc), **4 by omission**
(`setAveragingPeriod`, `setSource`, `setBackup`, `setChain`).

**CapDeployer vs production diff:** selector sets are identical (same omission). CapDeployer additionally grants
MINTER to the test contract and holds every role in one address; production (`WalletUsersConfig`) also holds
every role in one address — the broadcasting wallet — and makes it the beacon owner and the premium sink.

### Per-role worst case

| Role | Worst honest mistake | Worst malicious action | Moves depositor funds without matching accounting? |
|---|---|---|---|
| ADMIN (`users.admin`, Registry) | Repoint `Tranche.deposit` to PUBLIC; `addTranche` of wrong asset (F-I3) | `upgradeToAndCall` any singleton; `addTranche(maliciousContract)` on an underwriter → operator over its whole Vault balance; `setTargetFunctionRole` anything | **Yes** (by design; no delay) |
| Beacon owner (`users.admin`, Ownable) | Upgrade to wrong impl | Replace tranche/market/underwriter code → drain Vault | **Yes**, instantly, invisible to AccessManager (F-I1) |
| REGISTRY (Registry only) | — | Grant any operator role to anyone (it is their admin); `BeaconFactory.create` with any beacon/data | No direct fund movement; but it also holds ADMIN, so a Registry *upgrade* = ADMIN. Enumerated the Registry's own ADMIN usage: `setTargetFunctionRole` only on freshly-deployed instances and `irm`; `setRoleAdmin` only on fresh role ids; `grantRole` MINTER/MARKET only to fresh markets — no path lets KEEPER/GOVERNOR reach an arbitrary target through it |
| GOVERNOR | `setLiquiditySlopes` with huge base (unbounded, H8) mints unbacked yield; `setFixedCreditLimit` too high; assign wrong operator | Same, deliberately; `coverBadDebt` is self-funded | Indirectly (yield minted against no reserve — H1/H8, WS-E) |
| GUARDIAN | `setLt` below `ltv` → market instantly liquidatable; `setBuffer` up to `lt−ε` locks all tranche capital | Collude with LIQUIDATOR: drop `lt`, liquidate at `1+bonus` (≤10%) | Yes, but bounded by bonus and accounted (I3 holds); `writeOff` socialises to cUSD holders, bounded by `unrecoverableDebt` |
| KEEPER | Deploy market for the wrong operator pair; `extendAdmin` rolls a defaulted loan (H3, WS-D) | Same; cannot enable borrowing alone (new market has `ltv = 0`, `fixedCreditLimit = 0`; owner + GOVERNOR must act) | No |
| LIQUIDATOR | Liquidate with a hook-token recipient (F-4) | F-4 griefing; otherwise liquidation is at par + bonus | Only via F-4 (privileged + hook token) |
| MINTER / MARKET (markets only) | — | n/a (protocol code) | No; `slash` additionally checks `msg.sender == market` |
| Market owner (operator) | `setUnderwriterRate(0)`; `setLtv` to `lt − buffer`; bad weights | Same; admit anyone as tranche depositor | No — cannot withdraw; underwriters protected by GUARDIAN/GOVERNOR params only |
| Borrower (operator) | Over-borrow within limit | Default | Yes — that is the credit risk underwriters price |
| Curator (underwriter operator) | Allocate into a bad tranche; `setVestingPeriod` re-vests | Same; cannot exit to self (redeem goes to `address(this)`); admits depositors | No |
| Depositor | — | Front-run a slash via redeem (H2/H5, WS-C/B) | Only via stale-mark paths owned by other WS |
| Anyone | — | `Vault.deposit` re-entry (F-I2: no profit); `IRM.updateLiquidityRate` poke; `requestRedeem` spam | No |

---

## Storage layout verification

All ERC-7201 slots recomputed as `keccak256(abi.encode(uint256(keccak256(ns)) − 1)) & ~0xff` with `cast`, and
compared to (a) the hand-rolled constants and (b) `forge inspect <C> storage-layout` base slots on solc 0.8.36.

| Namespace | Recomputed slot | Matches |
|---|---|---|
| `cap.storage.BaseMarket` (hand-rolled, `BaseMarket.sol:24`) | `0x3084c044a22fd484d804b5e5eef3193432b474e4843f6459770a418b6e662700` | ✔ constant |
| `cap.storage.ERC7540AsyncRedeem` (hand-rolled, `:67`) | `0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300` | ✔ constant |
| `cap.storage.ERC7540Operator` (hand-rolled, `:333`) | `0x984a447e9a3f276a50a882321c9dcb50ab53cba0333a097400ab36b1a1a27200` | ✔ constant |
| `cap.storage.Registry` (`layout at`) | `0xa302af9f…8bcd00` | ✔ inspect (vault at +0 … `_trancheCount` at +0x10) |
| `cap.storage.BeaconFactory` | `0xa02682ef…50ff00` | ✔ (no own vars) |
| `cap.storage.Stablecoin` | `0xb4d0fed9…2b4000` | ✔ (`underlyingDecimals`+`irm` packed at +0, `creditBackedSupply` +1, `badDebt` +2) |
| `cap.storage.InterestRateModel` | `0xd89b2c63…be0000` | ✔ (+0 … `averagingPeriod` +0x14) |
| `cap.storage.Oracle` | `0xbcd42d77…44f900` | ✔ (+0..+2) |
| `cap.storage.Tranche` | `0x600efd58…180f00` | ✔ (+0..+0x0b) |
| `cap.storage.Underwriter` | `0xace93d61…592c00` | ✔ (+0..+0x0f) |
| `cap.storage.FixedMarket` | `0x3aef348c…7d8d00` | ✔ (+0..+6) |
| `cap.storage.FloatingMarket` | `0xccd94301…b6a400` | ✔ (+0..+3) |
| OZ `AccessManaged`, `ERC20`, `ERC4626`, `ERC6909`, `ERC6909TokenSupply`, `Initializable`, `ERC165` | `0xf3177357…`, `0x52c63247…`, `0x773e532d…`, `0x9e75074f…`, `0x9cc5ac14…`, `0xf0c57e16…`, `0xe7dc48d7…` | all distinct from every Cap namespace |

Derived-vs-base overlap: `FixedMarket`/`FloatingMarket` use `layout at` for their own plain variables;
`BaseMarket` has *no* plain variables (struct at its own hand-rolled slot), so the directive's region holds only
the derived contract's fields. `Tranche`/`Underwriter`/`Stablecoin` likewise: their plain fields sit at their
`layout at` base, `ERC7540AsyncRedeem`/`ERC7540Operator` structs at their hand-rolled slots, OZ bases at OZ
namespaces. `Vault` has no `layout at` and no own storage (all inherited namespaces) — fine. **No two regions
share a base, and every region is ≤ 0x15 slots wide, so no collision is possible short of a 256-bit hash
near-miss.** H13 is *not* confirmed. The one real upgrade hazard is F-I7 (inline library structs).

Initialization: every implementation constructor calls `_disableInitializers()` (all 10 checked); every
`initialize` is `initializer` (no `reinitializer`, so no post-upgrade re-init path exists — worth planning for);
all proxies are created with init data in the same transaction (`ProxyUtils._proxy`, `BeaconFactory.create`), so
there is no front-runnable uninitialised proxy. `BeaconFactory.create` is REGISTRY-only and `data` is always
Registry-built. Zero-address checks: Registry ✔ (all 10 addresses); `Tranche`/`Underwriter`/`IRM`/`Stablecoin`
initializers have none but receive Registry/DeployInfra-supplied values. `Stablecoin.initialize` refuses
`decimals > 18`; `< 6` (down to 0) is handled correctly by both previews. `AssetId` round-trip: `toId` is
`uint160`-exact; `toAsset` truncates high bits, but only `toId`-derived ids are ever minted, so ids ≥ 2^160 have
zero supply — cosmetic only.

---

## Loops / DoS

`F5_TrancheLoopGas.t.sol` (uniform-weight market, N tranches funded, borrow, price drop, liquidate 25%):

```
N=2   senior unlockedSupply gas=18102   healthiness gas=16197   liquidate gas=160134
N=10  senior unlockedSupply gas=65827   healthiness gas=68550   liquidate gas=443930
N=40  senior unlockedSupply gas=210582  healthiness gas=264868  liquidate gas=1625335
```

≈ 39k gas per tranche for `liquidate` (four full-array walks: `healthiness`, `maxLiquidatable`,
`recoverableDebt`, slash loop — each tranche costs an oracle `price` and a Vault call), ≈ 4.8k per tranche for a
senior-tranche `unlockedSupply`. A 30M block would need **N ≈ 750** tranches for liquidation to be un-includable.
`createTranche` is ADMIN-only and `_setTranches` is O(n²) on the same array, so this is not reachable by any
untrusted actor. Not a finding; recommend a sane cap (e.g. 16) in `_setTranches` anyway.

`Registry.createTranche` grows `_trancheCount` without bound — same conclusion.

---

## Signature / delegatecall / misc grep

`ecrecover`, `permit`, `delegatecall`, `selfdestruct`, `abi.encodePacked` hash use, `blockhash`,
`prevrandao`: **none** in `contracts/`. `tx.origin` only in `contracts/deploy/utils/WalletUtils.sol` (script
helper). `block.timestamp` is used only for accrual/expiry, never as randomness.
No `ReentrancyGuard` anywhere (confirmed by grep) — see F-4/F-I2/F-I9.

---

## Invariants

Broken (demonstrated): **I3** (F-4), **I5** (F-3, `maxLiquidatable` reverts on an unhealthy market),
**I16** (F-4).

New invariants the code implies that the plan missed:
- **I17 — Wiring:** for every `restricted` selector on every deployed instance, `getTargetFunctionRole` is one
  of the roles named in `ConfigureAccessControl`/`Registry` or explicitly ADMIN; no selector reaches 0 by
  omission. (Currently false: 4 selectors.)
- **I18 — Market defaults:** for every market, `lt <= 1e27`, `lt > buffer`, `ltv + buffer <= lt`,
  `targetHealth >= 1.25e27`, `targetHealth > (1 + liquidationBonus)·lt` — i.e. the setter predicates hold at
  birth, not only after the first setter call. (Currently false at birth for out-of-range registry defaults.)
- **I19 — Upgrade authority:** the set of keys that can change code behind any proxy ⊆ the set that can act
  as ADMIN through the AccessManager. (Currently false: beacon owners are Ownable outside it.)

---

## Appendix: gas & style (unranked)

- `foundry.toml`: `script = "scripts"` → `"script"`; the `fs_permissions` list and remappings reference
  Symbiotic/Eigen/LayerZero paths that no longer exist in the tree.
- `Registry._configureMarketRoles` wires seven `IFixedMarket` selectors onto floating markets (and vice versa);
  harmless but noisy in the role table. Split into per-kind wiring.
- `Registry.createMarket`/`createFixedMarket` take `string memory _name` while the rest of the args are
  `calldata`.
- `_setTranches` duplicate check is O(n²); use a transient set or require sorted input.
- `DeployLibs` returns a struct with a single `unused` field; `DeployInfra._deployInfra` takes an unused
  `delegationEpochDuration`; `DeployConfigs.VaultConfig/FeeConfig/LibsConfig` are dead.
- `WalletUtils.getWalletAddress` checks `tx.origin` against the foundry default sender — script-only logic
  living under `contracts/`.
- `Tranche.claim`/`Underwriter.claim` clamp to held balance (documented rounding); consider emitting the dust
  shortfall for observability.
- `RoleTable.t.sol` header claims 49 selectors; there are 61 `restricted` entry points (incl. 6 `upgradeToAndCall`) across the protocol.
