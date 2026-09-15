# WS-E — Mint/redeem, reserves, access control & upgrades

> **Post-verification status (lead, 2026-09-14):** E-1 Medium (residual of R2-H2, re-verified by WS-R; report R3-M3, merged with carried M-4). Lows/Infos unchanged.


Target `cap-network` @ `a843c1d`. Owns P12, P15, P16, P21, I40. PoCs: `audit/v3/tests/scratch/E/` (run with `FOUNDRY_TEST=audit/v3/tests/scratch/E forge test --match-path 'audit/v3/tests/scratch/E/*' -vv`; 23 tests, 21 pass, the 2 that fail are the two properties under test — E-1 and E-4). Role table deliverable: `audit/v3/findings/E-roletable.md`.

Read end to end: `Registry.sol`, `Stablecoin.sol`, `Wrapper.sol`, `Vault.sol`, `BeaconFactory.sol`, `InterestRateModel.sol`, `Oracle.sol`, `ChainlinkAdapter.sol`, `Tranche.sol`, `Underwriter.sol`, `market/{BaseMarket,FixedMarket,FloatingMarket}.sol`, `utils/{CapRoles,DeadShares,PremiumVesting}.sol`, `ERC7540/{ERC7540AsyncRedeem,ERC7540Operator}.sol`, `interfaces/{IAeraVault,IRegistry,IStablecoin,IOracle,IBaseMarket}.sol`, `script/Deploy.s.sol`, `script/deploy/service/{DeployInfra,ConfigureAccessControl,DeployImplems}.sol`, `script/config/Users.sol`, `config/cap-v2.json`, `config/README.md`, `test/integration/{RoleTable,Deployment}.t.sol`, `test/shared/CapDeployer.sol`, `test/shared/mocks/MockAeraVault.sol`, OZ 5.7.0 `AccessManager.sol` (`canCall`, `hasRole`, `_getAdminRestrictions`, `execute`) and `AccessManagedUpgradeable._checkCanCall`.

---

### [MEDIUM] E-1 — Reserve-loss recognition is a public GUARDIAN transaction; until it lands every surface quotes par, so the first holders to exit are whole and the remaining holders absorb 100 % of the loss (R2-H2 residual, P12)
**Location:** `contracts/cap/Stablecoin.sol:152-156` (`recognizeBadDebtInReserve`), `:184-192` (`unlockedSupply`), `:236-261` (`_convertToAssets`, par branch when `badDebt == 0`), `:102-117` (`invest`/`recall`, uncapped, no record); `contracts/ERC7540/ERC7540AsyncRedeem.sol:181-186` (`instantRedeem`), `:337-356` (`_claimableShares`).
**Impact:** After a loss `L` on the Aera leg and a partial `recall`, `badDebt == 0` so `convertToAssets`, `maxInstantWithdraw`, `claimableRedeemRequest`, `totalAssets` all quote par from the recalled balance. Anyone who redeems before the GUARDIAN's `recognizeBadDebtInReserve(L)` executes is paid par; after it, the exit curve socialises `L` over whoever is left. Round 2's fix (R2-H2) added the recognition entry point and the on-hand cap; it did not close the window between loss and recognition, and that window is not one block — it is however long the guardian takes to learn of the loss, size it and get the tx mined, plus the mempool exposure of the tx itself. The protocol reports itself covered (`totalAssets == totalSupply`) throughout. In the PoC (3 × 100, 30 % loss): holder 1 gets 100, holders 2–3 get 39.03 and 70.97 — 110 between them, i.e. the whole 90 loss; pro-rata would be 70 each.
**Likelihood:** Preconditions: `reserveVault` set (production intent; `Deploy.s.sol` leaves it `address(0)` until `RESERVE_VAULT` is given), KEEPER has invested, the Aera leg returns less than sent. Trigger: any cUSD holder who observes the loss (Aera state is public) or sees the guardian tx in the mempool. Cost: gas. The exit is `instantRedeem` or a pre-queued 4-arg claim; no capital at risk. Because the reserve leg is exogenous the *event* is rare, but given the event the run is the rational move for every holder.
**Exploit path:**
1. 3 holders deposit 100 each; KEEPER `invest(300)`; Aera loses 90 (mock: burn from the vault).
2. KEEPER `recall(300)` reverts (short); KEEPER `recall(210)` succeeds. `unlockedSupply() == 210`, `convertToAssets(100) == 100`, `totalAssets() == 300`.
3. Holder 1 `instantRedeem(100)` → receives 100 (or has a queued request and claims it: `claimableRedeemRequest == 100` at par).
4. GUARDIAN `recognizeBadDebtInReserve(90)` lands. `badDebt = 90`, supply 200, on hand 110.
5. Holder 2 exits → 39.03; holder 3 exits (needs 6 calls, see below) → 70.97. Net: holder 1 avoids 30 of loss; holders 2–3 carry 90 instead of 60.
**Proof:** `E_P12_FrontRun.t.sol::test_P12_frontRunRecognition_firstExiterWhole_restAbsorbAll` — fails on current code:
```
[FAIL: no holder should exit above pro-rata after a reserve loss: 100000000000000000000 > 70000000000000000000] test_P12_frontRunRecognition_firstExiterWhole_restAbsorbAll() (gas: 640385)
  holder1 (front-ran) received: 100000000000000000000
  holder2 received:             39032258064516129032
  holder3 received:             70967741935483870968
  sum:                          210000000000000000000
  stablecoin underlying left:   0
```
Queue variant (`test_P12_queueDrain_orderAndTailIterations`, passes as a demonstration): identical ordering (h1 100 at par via `redeem(id,…)` before recognition; h2 39.03; h3 70.97). The tail holder needs **6** claims because after recognition `unlockedSupply = supply − badDebt` (`Stablecoin.sol:186-188`) caps each call below the holder's remaining shares; each claim reduces `badDebt` via `_onWithdraw` and the next call unlocks more. The queue does drain fully (0 left on hand, 0 badDebt, 0 supply), and no claim reverts — I26 holds; the only ordering effect is who moves first.
Related observations proven in the same file: `test_investAll_freezesRedemptions_noCap` — `invest(all)` drops `unlockedSupply`, `maxRedeem`, `maxInstantRedeem` to 0 while `totalAssets` still reports 300 (there is no cap on `invest` relative to `redemptionQueue`); `test_recall_revertsWhenAeraIsShort` — `recall(all)` reverts after a loss, so holders are frozen until the keeper recalls a smaller amount.
**Recommendation:** Make loss recognition atomic with the observation rather than a separate discretionary tx: track `invested` in `invest`/`recall` and let `unlockedSupply`/`_convertToAssets` treat `invested − reserveVault-reported value` as provisional bad debt (or, if Aera cannot be valued on-chain, at minimum freeze instant and queued redemptions to `min(unlocked, onHand − pendingRecognition)` while a guardian-set "loss suspected" flag is up). Cap `invest` at a fraction of `unlockedSupply − redemptionQueue`. Submit `recognizeBadDebtInReserve` through a private relay in the meantime. Second-order: a provisional haircut changes `convertToAssets` for the Wrapper's `totalAssets`, so stcUSD pricing dips on suspicion rather than on recognition — that is the desired direction.
**Invariant broken:** I34 holds (balance ≥ queue + remaining), I35 holds; the plan's "un-writable, stated" invariant (`totalAssets` vs on-hand plus Aera) is exactly what fails here. Single promise: a depositor loses while the system reports itself covered.

---

### [LOW] E-2 — `recognizeBadDebtInReserve` has no reversal: an over-stated amount haircuts every exit although the reserve is whole, and the surplus is stranded forever
**Location:** `contracts/cap/Stablecoin.sol:152-156`, `:320-330` (`_onWithdraw`), `:170-181` (`coverBadDebt`).
**Impact:** `badDebt` can only fall through redemptions (`_onWithdraw`) or `coverBadDebt` (which burns caller cUSD, i.e. also shrinks the claim on the reserve). There is no `unrecognize`. If the guardian recognises 90 on a 300 reserve with no actual loss, the three holders exit with 54.4 / 68.1 / 87.5 (210 total) and 90 underlying remain in the contract with zero supply outstanding; nothing can ever pay them out (`previewDeposit` is par, `_convertToAssets` is par once `badDebt == 0`), so the surplus is permanently stranded absent an upgrade. A partial over-statement is the same in proportion. Early exiters lose to nobody in particular.
**Likelihood:** GUARDIAN honest mistake (wrong decimals, wrong amount, recognising before a partial recovery). GUARDIAN is protocol-trusted; no attacker.
**Exploit path:** 1. 3 × 100 deposited, no `invest`. 2. GUARDIAN `recognizeBadDebtInReserve(90e18)` by mistake. 3. Holders exit in turn. Result below.
**Proof:** `E_P12_FrontRun.t.sol::test_overRecognition_isIrreversible_strandsSurplus` (passes as a demonstration):
```
  no-loss over-recognition: h1 54444444444444444444 h2 68055555555555555555
  no-loss over-recognition: h3 87500000000000000001 stranded 90000000000000000000
```
**Recommendation:** Add a GUARDIAN/GOVERNOR `reduceBadDebt(amount)` bounded by `badDebt`, plus a `sweepSurplus` that pays `balanceOf(this) − totalAssets()` into `_fund` (so a recovery vests to holders instead of sitting idle). Second-order: `reduceBadDebt` moves the exit curve up, so it should be timelocked like `setReserveVault`.
**Invariant broken:** none in the plan; implies a new one — `IERC20(asset).balanceOf(stablecoin) − quoteWithdraw⁻¹(totalAssets)` should be reachable by holders.

---

### [LOW] E-3 — Trust model: `Deploy.s.sol` with no env vars puts ADMIN/GOVERNOR/KEEPER/GUARDIAN/LIQUIDATOR on one EOA with no delays; Registry holds ADMIN permanently and its UUPS upgrade (ADMIN by omission) is a full takeover; GOVERNOR+KEEPER can move the whole reserve out with no accounting update (P16)
**Location:** `script/config/Users.sol:17-29` (`envOr(..., wallet)` defaults), `script/deploy/service/ConfigureAccessControl.sol:14-29`, `script/deploy/service/DeployInfra.sol:57-60` (manager admin = deployer), `:147-149` (Registry granted ADMIN before init), `contracts/cap/Registry.sol:514` (`_authorizeUpgrade` `restricted`, selector never wired), `contracts/cap/Stablecoin.sol:102-124` (`invest`, `setReserveVault`).
**Impact:** (a) Default deploy: one key is every role; the config's `timelock`/`multisig` (`config/cap-v2.json`) are not referenced by any script; no `setGrantDelay`, no `setTargetAdminDelay`, so every ADMIN action (including `upgradeToAndCall` on all seven UUPS proxies and beacon `upgradeTo` via `execute`) is immediate. (b) The Registry must hold ADMIN (it calls `setTargetFunctionRole`); its own `upgradeToAndCall` resolves to role 0 by omission, so an ADMIN-signed upgrade of the Registry to arbitrary code can `grantRole(ADMIN, anyone)` in the same tx (`EvilRegistry` in the PoC). This is not an escalation over ADMIN — ADMIN can already do everything — but it is a second, un-asserted path to it and it is the reason `Registry` is the most sensitive proxy. (c) Two roles (or, by default, one key) drain the reserve: GOVERNOR `setReserveVault(X)` then KEEPER `invest(onHand)` sends everything to `X`; `totalAssets` still equals `totalSupply`, `badDebt == 0`, `unlockedSupply == 0`. No cap, no record, no timelock. `setSource` (GOVERNOR) to a malicious adapter and `recognizeBadDebtInReserve` overstated (GUARDIAN, E-2) are the other privileged fund-movement paths; `Oracle`/`IRM`/`Stablecoin` UUPS upgrades are ADMIN.
**Likelihood:** Key compromise or insider; single-key default deploy makes the blast radius total. Cost: one signature.
**Exploit path (c):** 1. holder deposits 1,000. 2. GOVERNOR `setReserveVault(thief)`. 3. KEEPER `invest(1000)`. 4. `balanceOf(stablecoin) == 0`, `thief` holds 1,000, `totalAssets() == totalSupply()`, `recall` reverts.
**Proof:** `E_P16_Deploy.t.sol` (all pass as demonstrations): `test_defaultDeploy_everyRoleOnOneEOA` (prints all five roles == broadcast wallet, `reserveVault == 0`), `test_postDeploy_roleHolders` (Registry holds ADMIN+REGISTRY; deployer dropped only when `ADMIN` differs; grant/admin delays 0), `test_registryUpgrade_isAdminByOmission_andIsFullTakeover` (`getTargetFunctionRole(registry, upgradeToAndCall) == 0`; GOVERNOR refused; ADMIN upgrade grants ADMIN to `attacker`), `test_beaconUpgrade_onlyAdminViaExecute`, `test_governorPlusKeeper_moveReserveWithoutAccounting`.
**Recommendation:** In `Deploy.s.sol` require `ADMIN`/`GOVERNOR`/`GUARDIAN` env vars (refuse the wallet fallback for these three the way `_users` refuses the Foundry sender); set `setTargetAdminDelay` on the seven proxies and the Registry, and `setGrantDelay(ADMIN)`; wire `upgradeToAndCall` explicitly to ADMIN in `_configureInfraRoles` so the table is complete; bound `invest` (E-1) and timelock `setReserveVault`. Second-order: an admin delay on the Registry target also delays `setTargetFunctionRole(registry, …)`, which is desirable.
**Invariant broken:** I40 (see E-4).

Per-role worst cases (as wired at a843c1d):

| Role | Worst honest mistake | Worst malicious action |
|---|---|---|
| ADMIN (0) | grant a role to the wrong address; upgrade to a broken impl | upgrade any of 7 proxies / 4 beacons to a drainer; rewire any selector to PUBLIC; grant self every role — total |
| GOVERNOR (2) | `setReserveVault(0)` strands the invested leg (no migrate); bad slopes; `setSource` to a wrong-scale feed | `setReserveVault(thief)` (needs KEEPER to `invest`); `setSource` to a rigged adapter → over-borrow (WS-D); `setFixedCreditLimit(max)` |
| KEEPER (3) | `invest(all)` freezes every redemption (E-1 obs.); `extendAdmin` rolls a dead loan | `invest(all)` to whatever `reserveVault` is; permanent redemption freeze until recall |
| GUARDIAN (1) | over-recognise (E-2, irreversible); `setLt` just above buffer forces every market unhealthy | `writeOff` any market to `unrecoverableDebt` at will; `setBuffer`/`setLt` to lock tranche exits (`lockedValue = debt/(lt−buffer)`) |
| LIQUIDATOR (6) | none beyond gas | withhold liquidation (liveness — WS-D) |
| MARKET (4) / PROTOCOL (8) | contract-held, no EOA | n/a unless a beacon is upgraded (ADMIN) |
| WHITELISTED (7) | none granted by script | P14 composition (lead); `createChildRoles` with any parent — no escalation (E_P15 test) |
| market owner (≥100) | `setDepositorRole(PUBLIC)` (E-5) | P14; `setBorrowerRole` to own role; `setTrancheWeights` to starve seniors |
| curator (≥100) | `removeTranche` strands premium (P17, WS-C) | `addTranche(arbitrary)` drain (P1, WS-C); `setDepositorRole(PUBLIC)` |

---

### [LOW] E-4 — 17 `restricted` selectors resolve to ADMIN(0) by omission; ADMIN can borrow from a market and deposit into / allocate from an underwriter before their owner/curator wires roles, and `RoleTable.t.sol` cannot see it (I40)
**Location:** `contracts/cap/Registry.sol:351-417` (`_configureInfraRoles` never wires `upgradeToAndCall`), `:422-464` (`_configureMarketRoles` leaves `borrow`/`borrowMore` unwired), `:496-511` (`_configureUnderwriterRoles` leaves allocator and depositor selectors unwired); `test/integration/RoleTable.t.sol:38-40` + `test/shared/CapDeployer.sol:315-321,555-573` (roles set before the table is read).
**Impact:** Per `E-roletable.md`: 7 × `upgradeToAndCall` (intended ADMIN, reached by default), 3 borrow selectors on any market whose owner has not called `setBorrowerRole`, 7 selectors on any underwriter whose curator has not called `setAllocatorRole`/`setDepositorRole`. In the fresh window ADMIN can `deposit` into a third-party curator's vault (and immediately `allocate` it into any registered tranche, or `setDefaultTranche`), and can `borrow` from a third-party owner's market. ADMIN is trusted, so no unprivileged loss; the defect is that the intended role graph has holes the tests do not model, and the RoleTable header's premise ("a forgotten selector and one deliberately held at ADMIN are indistinguishable from storage") is exactly the situation.
**Likelihood:** Always present for every new instance until the owner/curator acts; observable only by reading storage.
**Exploit path:** n/a (privileged). Demonstration: `E_P15_RoleGraph.t.sol::test_freshMarket_borrowResolvesToAdminByOmission` — `canCall(ADMIN holder, freshMarket, borrow) == true`.
**Proof:** `E_RoleTable.t.sol::test_I40_noRestrictedSelectorResolvesToAdminByOmission` — fails on current code with the 17 rows listed in `E-roletable.md`:
```
[FAIL: restricted selectors resolving to ADMIN(0) without explicit wiring: 17 != 0] test_I40_noRestrictedSelectorResolvesToAdminByOmission() (gas: 3033127)
```
**Recommendation:** In `_configureMarketRoles` wire the three borrow selectors, and in `_configureUnderwriterRoles` the seven allocator/depositor selectors, to a fresh operator role with no members (or to the owner/curator role), so nothing on a fresh instance falls through to ADMIN; wire `upgradeToAndCall` on all seven proxies to ADMIN explicitly in `_configureInfraRoles`; add the fresh-state and the seven upgrade rows to `RoleTable.t.sol` and assert refusal for non-ADMIN holders (`test_upgradeToAndCall_isAdminOnly_onAllSevenProxies` in the E scratch dir is a drop-in). Second-order: none.
**Invariant broken:** I40.

---

### [LOW] E-5 — `Registry.setDepositorRole` has no `PublicRole`/`isOperatorRole` guard: a market owner or curator can open a tranche or underwriter to PUBLIC or wire its `deposit/mint` to a protocol role (P15)
**Location:** `contracts/cap/Registry.sol:202-210` vs `:213-215`, `:229-231`.
**Impact:** `setBorrowerRole`/`setAllocatorRole` reject `PUBLIC_ROLE` and non-operator roles; `setDepositorRole` accepts anything. A market owner can make a junior tranche permissionless (anyone with Vault balance and `setOperator(tranche)` deposits), or wire `deposit` to GUARDIAN/PROTOCOL/REGISTRY (every market, tranche and underwriter then may deposit). Permissionless junior deposits are the depositor's own capital at risk, so on its own this is not a loss path; it matters because it removes the one gate that made "depositor" an allow-list, and because P14 (lead) needs a depositor to seed the thin junior — with PUBLIC the owner does not even need to grant itself the role. Also asymmetric with the NatSpec on `Tranche.deposit` ("Caller must have the depositor role").
**Likelihood:** Any market owner / curator, one call.
**Exploit path:** 1. owner `ITranche(t).setDepositorRole(type(uint64).max)`. 2. stranger `vault.deposit` + `setOperator(t)` + `t.deposit` succeeds.
**Proof:** `E_P15_RoleGraph.t.sol::test_setDepositorRole_acceptsPublicAndProtocolRoles_setBorrowerRoleDoesNot` (passes as a demonstration; `setBorrowerRole(PUBLIC)` reverts `PublicRole`, `setDepositorRole(PUBLIC)` succeeds on tranche and underwriter, GUARDIAN and PROTOCOL also accepted).
**Recommendation:** Apply the same two checks; if a permissionless tranche is a wanted feature, make it explicit (`setDepositorRole(PUBLIC)` allowed but reject ids `< FIRST_OPERATOR_ROLE`). Second-order: the harness's `_deployUnderwriter` passes operator roles, so tests are unaffected.
**Invariant broken:** none.

---

### [LOW] E-6 — `Registry.createTranche` checks `hasRole` and discards the execution delay, bypassing any delay ADMIN attached to the owner-role grant (P15)
**Location:** `contracts/cap/Registry.sol:177-199` (`createTranche`, `(bool isOwner,) = hasRole(...)`).
**Impact:** OZ's `restricted` honours `grantRole(role, account, executionDelay)` by forcing `schedule`+`execute`; `createTranche` is the only owner action not behind `restricted`, so a delayed owner can add a junior tranche (and, via P14, the depositor role it administers) immediately while every other owner action on that market waits. If governance uses execution delays as the timelock for third-party owners (the only timelock primitive the deployment offers), this is the hole in it.
**Likelihood:** Requires ADMIN to have granted the owner role with a delay; owner is a third party.
**Exploit path:** 1. ADMIN `grantRole(ownerRole, owner, 1 days)`. 2. owner `setLtv` reverts `AccessManagerNotScheduled`. 3. owner `createTranche(market, asset, weights)` succeeds at once.
**Proof:** `E_P15_RoleGraph.t.sol::test_createTranche_ignoresExecutionDelay` (passes as a demonstration).
**Recommendation:** Make `createTranche` `restricted` and wire it per market? It is a Registry selector, so instead: `(bool isOwner, uint32 delay) = hasRole(...); if (!isOwner || delay != 0) revert NotMarketOwner();` — or move tranche creation onto the market (`BaseMarket.createTranche` `restricted` → Registry `PROTOCOL` forwarder, like the role setters). Second-order: none.
**Invariant broken:** none.

---

### [INFORMATIONAL] E-7 — `setBorrowerRole` accepts an operator role administered by another party; that party then controls this market's borrower list
**Location:** `contracts/cap/Registry.sol:213-226`.
**Impact:** Owner A wires `borrow` to role R whose admin is B's role; B grants/revokes R members at will and A cannot revoke (`AccessManagerUnauthorizedAccount`). It is A's explicit choice (A picked R), so no third-party loss; but the interface gives no warning and there is no way for A to later take R's admin. Proof: `E_P15_RoleGraph.t.sol::test_setBorrowerRole_crossOwnerRoleHandsMembershipToOtherAdmin`. Fix: require `getRoleAdmin(roleId) == marketOwnerRole(msg.sender)` (or `== ownerRole` given at create), same for `setAllocatorRole`.

### [INFORMATIONAL] E-8 — `marketOwnerRole` is derived from `setLtv`'s live wiring only; rehoming one selector splits the "owner"
**Location:** `contracts/cap/Registry.sol:267-271`.
**Impact:** ADMIN `setTargetFunctionRole(market, [setLtv], X)` makes X the owner for `createTranche` and the admin of every *new* depositor role while the other six owner selectors stay with the old role (`test_marketOwnerRole_followsSetLtvOnly`). `RoleTable.t.sol:292` documents this as intended. Recommend storing the owner role in Registry at create (or reading all seven and requiring agreement), so that rehoming is all-or-nothing.

### [INFORMATIONAL] E-9 — No pause and no redemption circuit-breaker; the only de-facto freeze is KEEPER `invest(all)`
**Location:** protocol-wide; `Stablecoin.sol:184-192`.
**Impact:** There is no `pause` on any contract. GUARDIAN's emergency levers are `setLt` (must stay `> buffer`; dropping below `ltv` forces every position unhealthy so LIQUIDATOR can act, and raises `lockedValue = debt/(lt−buffer)` so tranche exits shrink), `setBuffer`, `writeOff`, `recognizeBadDebtInReserve`. GOVERNOR can `setFixedCreditLimit(0)` (stops new credit only) and `setSource(asset, [])` (legal: `length != 0 &&` guard) which zeroes the price and makes every `totalCapital`/`healthiness`/`liquidate`/`borrow`/`writeOff` on that market revert — a market-wide freeze that also freezes liquidation (P11, WS-D). For cUSD itself the only freeze is `invest(all)` → `unlockedSupply == 0`, which also has no "unfreeze on loss" semantics (E-1). Concrete worst case: a discovered exploit on a market cannot be stopped without either killing its price feed (freezes liquidations too) or upgrading. Trap check: `setLt` low with no liquidator does not trap funds (borrowers can still `repay`; depositors are locked by design while debt is outstanding); `setFixedCreditLimit(0)` stops new credit only. Recommend an explicit `Pausable` on `borrow`/`instantRedeem`/`requestRedeem` claims with GUARDIAN pause / GOVERNOR unpause, and an `invest` cap.

### [INFORMATIONAL] E-10 — `previewDeposit` is par during a shortfall: a newcomer subsidises earlier holders by `badDebt/(S+D)` of backing immediately
**Location:** `contracts/cap/Stablecoin.sol:204-213`.
**Impact:** Documented ("Always at par, even with bad debt"). Number, after the E-1 scenario (S=300, B=90 recognised): a 100 deposit mints 100 shares; backing per share becomes 0.775 (22.5 % backing loss on arrival = `90/400`), and the exit quote for those 100 shares is 63.64 (36 % on the exit curve). Proof: `test_depositDuringShortfall_immediateLoss`. Whether intended is a product decision; if it is, integrators (Wrapper, routers) should read `badDebt()` before quoting. Note the mint also raises `unlockedSupply` for earlier holders, i.e. new deposits are the recovery mechanism.

### [INFORMATIONAL] E-11 — `fund()` and I34: the premium pot and the redemption queue share `balanceOf(this)`; the design holds except for rounding dust (inconclusive)
**Location:** `contracts/cap/Stablecoin.sol:77-86`, `contracts/utils/PremiumVesting.sol:142-155` (`claim` clamp), `:253-259` (`_checkpoint`), `contracts/ERC7540/ERC7540AsyncRedeem.sol:445-457` (`_consumeRequest` burns from `address(this)`).
**Analysis:** Every `_fund(x)` is matched by `x` shares landing on `address(this)` first (`fund` → `deposit(premium, this)`; `fundCreditBacked` → `_mintCreditBacked(this)`; `Tranche.fund` is MARKET-only and the market mints to the tranche first; `Underwriter._report` funds exactly what `claim` returned). `address(this)` and `DeadShares.HOLDER` can never opt in (`optIn` early-return), so queued shares never earn. Σ entitlements ≤ vested by the floor in `_accrue`, except that `_checkpoint`/`_settle` compute `owed(perShare_new, bal) − debt` where `debt = owed(perShare_old, bal)` — two independent floors, so each checkpoint can over-attribute by 1 wei per account. With many opted-in accounts checkpointing often, Σ claims can exceed the pot by a few wei; `claim` then clamps to `balanceOf(this)` and pays those wei out of *queued* shares, after which the final `_consumeRequest` `_burn(this, shares)` reverts by that many wei and the last queued redeemer must claim `shares − dust`. Could not demonstrate in bounded time (needs a many-account fuzz); WS-B's I33/I34 handler is the right place. Fix if confirmed: clamp `claim` to `balanceOf(this) − redemptionQueue()` (not to the whole balance).

---

## Stablecoin mint/redeem accounting notes (item 5)

- `coverBadDebt` burns `msg.sender`'s cUSD and lowers `badDebt` by the same amount: `creditBackedSupply + badDebt ≤ totalSupply` (I35) is preserved (both sides fall by `c`), `unlockedSupply` unchanged. Burning *credit-backed* cUSD this way does not touch `creditBackedSupply` — consistent, since credit is a supply-level quantity, not per-token.
- `recognizeBadDebtInCredit` decrements `creditBackedSupply`; `FixedMarket.writeOff` decrements `_totalDebt` by the same `amount`; `FloatingMarket.writeOff` passes `cleared` from `_repayWithin` to `_writeOff` and reduces `scaledDebt` so `totalDebt` falls by exactly `cleared` — I30 consistent on both.
- `burnCreditBacked(msg.sender-of-market)`: in `_liquidate` the LIQUIDATOR must hold cUSD (repays debt, receives collateral) — by design. `FixedMarket.repay(id, amount)` lets anyone repay anyone's loan from their own balance — a donation path, harmless. `FixedMarket.extend`/`borrowMore` are gated on the borrower *role*, not the loan's opener, so any borrower-role member can extend/borrow-more on any loan id of that market (WS-G/P7 note).
- `Stablecoin.deposit/mint` are not `restricted` (ERC4626 defaults) — confirmed public; `fund`/`coverBadDebt` public.

## Upgradeability (item 6)

- `_disableInitializers()` in every constructor: Registry, Stablecoin, Wrapper, Vault, BeaconFactory, IRM, Oracle, Tranche, Underwriter, BaseMarket (+ redundant repeats in FixedMarket/FloatingMarket — harmless). All `initialize` use `initializer`; none use `reinitializer`. `E_P16_Deploy.t.sol::test_initializers_cannotRerun` — every proxy and every implementation reverts `InvalidInitialization`. Live-proxy consequence (cUSD/stcUSD already at version 1 ⇒ `underlyingDecimals/irm/reserveVault` never set, `Wrapper.initialize`'s `optIn` never runs) is P22 — WS-U, not duplicated here.
- ERC-7201 constants recomputed (`keccak256(abi.encode(uint256(keccak256(ns)) − 1)) & ~0xff`): `cap.storage.ERC7540AsyncRedeem` = `0x8bbfa7ff…5c0300` ✓, `cap.storage.ERC7540Operator` = `0x984a447e…27200` ✓, `cap.storage.PremiumVesting` = `0xcd5f59be…d1c00` ✓, `cap.storage.BaseMarket` = `0x3084c044…62700` ✓ — all four match the hard-coded values.
- `layout at erc7201(...)` contracts: `forge inspect` base slots — (decimal, first 8 digits…last 6) Registry 73731740…242880, Stablecoin 81785575…366400, Tranche 43448517…479296, Underwriter 78209908…577536, FixedMarket 26656784…862016, FloatingMarket 92655689…674368, IRM 97973742…393536, Oracle 85409700…330368; Wrapper, BeaconFactory, Vault have no plain state. No two namespaces share a base; no base contract carries its own `layout at` (BaseMarket/PremiumVesting/ERC7540* use explicit `$.slot` structs), so nothing is overridden. OZ's own namespaces (`openzeppelin.storage.*`) are disjoint by string.
- Unbounded loops: `_setTranches` O(n²) and `_chargePremium`/`totalCapital`/`lockedValue` O(n) are bounded by the market owner (`createTranche` one at a time; `setTranches` REGISTRY-only) and only affect that owner's market; `_claimFifo`/`maxRedeem` over a controller's request set is P2 (WS-B).
- `Wrapper` `ERC20Permit` domain name `"Staked " + asset.name()` with version "1", chainId and `verifyingContract` — no cross-chain or cross-contract replay. Fine.

## Invariants

- **I40** — broken (E-4): 17 `restricted` selectors resolve to ADMIN by omission; table in `E-roletable.md`.
- **I26** — holds on the reserve path (queue drains fully after recognition; tail needs 6 iterations, none revert).
- **I34/I35** — hold in every E scenario; I34 dust risk noted (E-11).
- New: **E-I1** "no holder exits above pro-rata once the reserve is impaired" — violated by design between loss and recognition (E-1). **E-I2** `balanceOf(stablecoin) − assetsFor(totalSupply)` must be holder-reachable — violated after over-recognition (E-2). **E-I3** for every deployed instance and every `restricted` selector, `getTargetFunctionRole != 0` unless `_configure*` names ADMIN — the strict I40 form the tests should enforce.

## Hypotheses

- **P12** — CONFIRMED (Medium, E-1): first exiter paid par before recognition; the other holders carry 100 % of the loss; `invest` uncapped freezes redemptions; `recall` reverts when Aera is short; queue drains in order, tail needs repeated claims but is fully paid.
- **P15** — CONFIRMED as Low/Informational (E-5, E-6, E-7, E-8): `setDepositorRole` unguarded; `createTranche` ignores delay; foreign-administered borrower role accepted; `marketOwnerRole` reads one selector. `createChildRoles` arbitrary parent gives no escalation; shared counter cannot collide; uint64 exhaustion impossible.
- **P16** — CONFIRMED (Low, E-3): default deploy = one EOA for all five roles, no delays, `reserveVault = 0`; Registry `upgradeToAndCall` is ADMIN by omission and is a takeover; beacons ADMIN-via-`execute` only; WHITELISTED never granted by script.
- **P21** — CONFIRMED (style, Appendix): `BaseMarket.setDepositorRole` wires dead selectors; `IncompleteClaim` outer checks unreachable.
- **I40** — BROKEN (E-4).

## Appendix: gas & style

- `BaseMarket.setDepositorRole` → `Registry.setDepositorRole` wires `IERC4626.deposit/mint` on a market that has neither function (`E_P15::test_marketSetDepositorRole_wiresDeadSelectors`); `IBaseMarket.setDepositorRole` NatSpec says "permitted to deposit into the market". Remove from `BaseMarket`/`ownerSelectors[6]`.
- `Registry._configureMarketRoles` `ownerSelectors[3] = IFixedMarket.extend` is overwritten by every `setBorrowerRole`; live only between create and the first `setBorrowerRole`, when no loan can exist. Dead wiring; also wires fixed-only selectors (`extend`, `extendAdmin`, `setTermLimits`, `writeOff(uint256)`, `liquidate(uint256,…)`, `borrow(…,uint256)`, `borrowMore`) on floating markets and `writeOff()`/`liquidate(address,uint256)`/`borrow(address,uint256)` on fixed markets — harmless (no code at those selectors) but the table carries 10 dead rows per market.
- `ERC7540AsyncRedeem.redeem/withdraw` (3-arg): `if (consumed != _shares) revert IncompleteClaim` after `_claimFifo`, which already reverts `IncompleteClaim` on the same condition (`:403`). Unreachable.
- `ConfigureAccessControl._initInfraAccessControl:17-18` re-grants ADMIN/REGISTRY to the Registry already granted in `DeployInfra:148-149` (no-op, emits nothing new).
- `FixedMarket`/`FloatingMarket` constructors repeat `_disableInitializers()` already done in `BaseMarket`'s constructor.
- `RoleTable.t.sol` header claims 58 gated selectors; it asserts 50 distinct rows and none of the seven `upgradeToAndCall`s.
- `Users._users()` refuses Foundry's default sender — good; consider refusing the wallet fallback for `ADMIN`/`GOVERNOR`/`GUARDIAN` as well (E-3).
