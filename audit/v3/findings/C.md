# WS-C — Coverage accounting & underwriter collateral (round 3, HEAD `a843c1d`)

> **Post-verification status (lead, 2026-09-14):** C-1 High (carried R2-H1, re-verified by WS-R); C-2 **High confirmed** (`verify/C-2.md`: entry-leg loss bounded by `L`, single-victim with a default tranche). Lows/Infos unchanged. Report IDs: R3-H2, R3-H3.


Files read end to end: `contracts/cap/Tranche.sol`, `Underwriter.sol`, `Vault.sol`, `Registry.sol`,
`contracts/cap/market/{BaseMarket,FloatingMarket,FixedMarket}.sol`, `contracts/utils/PremiumVesting.sol`,
`contracts/ERC7540/{ERC7540AsyncRedeem,ERC7540Operator}.sol`, `contracts/interfaces/{ITranche,IUnderwriter,IBaseMarket}.sol`,
OZ 5.7.0 `ERC4626Upgradeable` (`deposit`/`_deposit`/`_transferIn` ordering), plus the round-1/2 verification
reports `HIGH-STALE-MARK.md` and `R2-HIGH-CURATOR-DRAIN.md`.

PoCs: `audit/v3/tests/scratch/C/` — run with
`FOUNDRY_TEST=audit/v3/tests/scratch/C forge test --match-path 'audit/v3/tests/scratch/C/*' -vv`.
27 tests: **7 fail by design** (C-1 ×3, C-2 ×4 — each asserts the property that should hold), 20 pass
(including the two I37 invariants, ~100k handler calls). Output pasted verbatim under each finding.

Summary: **2 High, 0 Medium, 3 Low, 5 Informational.** Both Highs are regressions of round-1/2 findings
that HEAD "fixed" by NatSpec declaring the behaviour intentional; under Matt's decision (curators are third
parties; "depositor loses money while the system reports itself covered" is the tiebreaker) both stand.

---

## 0. Coverage math, derived from code (units at every step)

Notation: `p` = oracle price of a tranche asset, 18-dec USD per whole token (`IOracle.price`, checked ≠ 0 in
`Tranche.getPrice` :216-219); `dec` = asset decimals; `A` = tranche ERC-6909 balance in asset-wei
(`Tranche.totalAssets` :103-105 — the Vault balance, nothing else); `S` = tranche share supply; `D` =
`market.totalDebt()` in cUSD-wei (18 dec); `lt, buffer, ltv` in ray.

| Quantity | Formula (rounding) | Units | Source |
|---|---|---|---|
| `Tranche.totalCapital` | `A · p / 10^dec` (floor; 0 without oracle call when `A == 0`) | USD-wei (1e18) | Tranche.sol:177-181 |
| `Tranche.activeAssets` | `convertToAssets(S − redemptionQueue)` = `(S−q)·(A+1)/(S+1)` (floor) | asset-wei | ERC7540AsyncRedeem.sol:282-289 |
| `Tranche.activeCapital` | `activeAssets · p / 10^dec` (floor) | USD-wei | Tranche.sol:184-188 |
| `BaseMarket.totalCapital` | `Σ_t totalCapital(t)` — walks every tranche, every oracle | USD-wei | BaseMarket.sol:292-297 |
| `debtLiquidationThreshold` | `rayMul(totalCapital, lt)` (half-up, ≤ 0.5 wei in favour of health) | USD-wei | :224-227 |
| `healthiness` | `rayDiv(threshold, D)` (half-up); `1e27` when `D == 0` | ray | :230-234 |
| `variableCreditLimit` | `rayMul(Σ_t activeCapital(t), min(ltv, lt))` | USD-wei | :315-322 |
| `creditLimit` | `min(fixedCreditLimit, variableCreditLimit)` | USD-wei | :307-310 |
| `lockedValue(t)` | `R = ceil(D · RAY / (lt − buffer))`, then for each tranche strictly junior to `t`: `R −= totalCapital(j)` (saturating to 0) | USD-wei | :270-289 |
| `Tranche.unlockedSupply` | `0` lock ⇒ `S` (no oracle); else `lockedAssets = ceil(locked · 10^dec / p)`, `lockedShares = ceil(lockedAssets · (S+1)/(A+1))`, `unlocked = S − lockedShares` (saturating) | shares | Tranche.sol:163-174 |
| `instantUnlockedSupply` | `unlockedSupply − redemptionQueue` (saturating) | shares | ERC7540AsyncRedeem.sol:301-305 |

Cross-checks that hold:
- `setLtv` enforces `ltv + buffer ≤ lt` (:71-76), `setBuffer` `buffer < lt` (:79-86), so `lt − buffer ≥ ltv > 0`:
  the `lockedValue` divisor is never zero and `1/(lt−buffer) ≤ 1/ltv`. Therefore after every permitted exit the
  remaining capital satisfies `Σ cap ≥ D/(lt−buffer)`, i.e. `healthiness ≥ lt/(lt−buffer) = 1.143` at
  deploy defaults (0.8/0.7). `test_lockedValue_appendedJuniorUnlocksSenior` shows exactly that floor (health
  `1.152e27` after the senior leaves).
- Every rounding is in the conservative direction: `lockedValue` ceil, junior capital floor (subtracts less),
  `unlockedSupply` ceil twice, `slash` floor twice (delivers ≤ requested, remainder passed on — WS-D P10).
- **Credit is sized on `activeCapital`, health on `totalCapital`.** Queued-for-redemption shares count for
  health and locking but not for new credit. `test_queuedSharesCountForHealthNotCredit`: after the sole
  depositor queues everything against 500 of debt, `activeCapital = 1000` wei (the dead-share seed),
  `creditLimit = 500` wei, `healthiness` stays `1.6e27`, and only `S − ceil(lockedShares) =
  285.714285714285714285e18` of 1000e18 is claimable. The remaining 714.29 waits on the borrower; on a
  floating market nothing forces repayment, so a depositor's exit horizon is the borrower's. Defensible
  (documented in `ITranche.unlockedSupply` NatSpec) but it means "I asked to leave" gives no protection
  against a subsequent slash — the queued shares are slashed like everyone else's (`Tranche.slash` burns
  from `totalAssets`, not from holders).
- The ratio is **live** everywhere in the market (`totalDebt` is index-derived, `totalCapital` walks the
  oracles) and **cached** in exactly one place: `Underwriter.totalDebt` (C-2).
- Movable inputs: `p` is GOVERNOR-sourced (`Oracle.setSource`), not owner-movable; `setTrancheWeights`
  only touches premium split (weights are read solely in `_chargePremium` :455); `createTranche` is the one
  owner lever on coverage — it appends a junior whose `totalCapital` unlocks every senior one-for-one (§C-9,
  numbers for the lead's P14). A thin junior asset only enters if GOVERNOR has listed a feed for it.

## Findings

### [HIGH] C-1 Curator registers any contract as a "tranche" and moves 100% of the underwriter's vault balance (P1, R2-H1 regression)
**Location:** `contracts/cap/Underwriter.sol:90-100` (`addTranche`: `_registeredTranches.add`, `IVault.setOperator(_tranche, true)`, `IPremiumVesting(_tranche).optIn()` — no check on `_tranche`); `contracts/cap/Registry.sol:499-504` (`addTranche`/`removeTranche` on the curator operator role), `:116-134` (`createChildRoles`: any WHITELISTED address mints operator roles with arbitrary parent and pre-granted members), `:245-264` (`createUnderwriter` WHITELISTED); `contracts/cap/Vault.sol:51-53` + `ERC7540Operator.sol:31-34` (ERC-6909 operator = unlimited `transferFrom` on every id).
**Impact:** every depositor's idle balance leaves in one call; the allocated part is reachable to the extent the market has not locked it, because the same curator administers the allocator role (`setAllocatorRole`, :85-87) and `deallocate`s first. In the PoC: 1,500e18 idle → 0; with 1,000 allocated and 350 of debt, 1,000 of 1,500 leaves (the 500 the market locks stays). Depositor shares quote at 0 (`maxInstantWithdraw(alice) == 0`). New on HEAD: `removeTranche(fake)` no longer reverts (`_report` is skipped when `debt[fake] == 0`, :104), so the thief also clears the operator flag afterwards.
**Likelihood:** attacker = any holder of WHITELISTED (granted by ADMIN; `Deploy.s.sol` grants it to nobody, so it is an onboarding decision) — or any curator role holder however obtained. Cost: gas. No timing, no oracle, no victim interaction beyond having deposited. HEAD's only mitigation is the NatSpec "curator is trusted to name a real protocol tranche" (`Underwriter.sol:92`, `IUnderwriter.sol:83-86`), added in `2429b6c` (this round's delta, after R2-H1 was reported). The warning it replaces — "Registration is held above the curator on purpose … a curator … could register a contract of their own and move the balance out" — was written in `365a040` and deleted in `3dad5ef` together with the move of `addTranche`/`removeTranche` to the curator role (`git log -S"held above the curator" -- contracts/cap/Registry.sol` → `3dad5ef`, `365a040`). The code path is byte-for-byte the round-2 one; only the comment changed. Under Matt's decision curators are third parties, so this is a trust gap, not an assumption.
**Exploit path:**
1. ADMIN grants WHITELISTED to `attacker` (onboarding). Attacker: `registry.createChildRoles(anyParent, [[attacker]])` → `curatorRole`; `registry.createUnderwriter(collateral, …, curatorRole)` → `uw`; `createChildRoles(curatorRole, [[alice, bob]])` → depositor role; `uw.setDepositorRole(it)`.
2. Alice deposits 1,000, Bob 500 (vault operator set on `uw`, `uw.deposit`). `uw.totalAssets() == 1,500e18`.
3. Attacker deploys `Drain { optIn(){} pull(){ vault.transferFrom(uw, attacker, asset, balanceOf) } }` and calls `uw.addTranche(drain)` — passes: `add`, `setOperator(drain, true)`, `drain.optIn()`.
4. `drain.pull(...)` moves 1,500e18; `vault.withdraw` to plain ERC-20. Net: +1,500e18 for the attacker, −100% for depositors. Optional: `uw.removeTranche(drain)` clears the flag.
5. Allocated funds: `setAllocatorRole(own)`, `deallocate(t, max)` (returns `min(balance, instantUnlockedSupply)`), then step 4.
**Proof:** `audit/v3/tests/scratch/C/C1_CuratorDrain.t.sol` — all three fail on HEAD (each asserts the property that should hold):
```
[FAIL: a curator must not be able to move depositor balances: 0 != 1500000000000000000000] test_P1_curatorDrainsIdleBalance_productionWiring()
  victim TVL before (wei):           1500000000000000000000
  moved by curator (wei):            1500000000000000000000
  attacker ERC20 balance after (wei): 1500000000000000000000
  underwriter totalAssets after:     0
  alice maxInstantWithdraw after:    0
[FAIL: depositor capital must survive curator action: 0 != 1500000000000000000000] test_P1_curatorCleansUpAfterwards()
[FAIL: depositor capital must survive curator action: 499999999999999999000 != 1500000000000000000000] test_P1_allocatedSharesReachableViaAllocatorRole()
  tranche0 unlocked shares while 350 debt outstanding: 500000000000000000000
  freed by deallocate (shares): 500000000000000000000
  moved by curator (wei):       1000000000000000000000
  left in tranche0 (locked):    500000000000000000000
```
No mocks, no pranked protocol role on the attack path: the only privileged action is the initial WHITELISTED grant; every later call is the attacker under its own operator roles through `Registry`'s production wiring.
**Recommendation:** (1) `Registry` records every tranche it deploys (`mapping(address => bool) isTranche`, set in `_deployTranche`), and `Underwriter.addTranche` requires `IRegistry(registry).isTranche(_tranche) && ITranche(_tranche).asset() == asset()` — the Underwriter already stores `registry` (:32). (2) Drop the blanket operator: in `_allocate`, `IVault(vault).approve(tranche, id(asset), assets)` for exactly the amount being allocated (OZ ERC-6909 has per-id allowances) so even a real tranche can pull only what is being allocated; `Tranche._transferIn` already uses `transferFrom`, which honours allowances. (3) Until then, put `addTranche`/`removeTranche` back on ADMIN/GOVERNOR (the `3c45dca` wiring) and restore the deleted comment. Second-order: (2) also closes the same-asset-different-market operator scope; tests that use `vault.setOperator(tranche, true)` for direct depositors are unaffected (that is the depositor's own operator grant).
**Invariant broken:** I25 (`∀ o: Vault.isOperator(underwriter, o) ⇒ Registry-deployed tranche of the same asset`) — never held; no code asserts it.

### [HIGH] C-2 Underwriter share price is a stale cache: exits after a slash are over-paid and entries are over-charged — including inside the very `deposit` that refreshes the book (P4, H-1 regression, both legs)
**Location:** `contracts/cap/Underwriter.sol:243-245` (`totalAssets = idle + totalDebt`), `:187-203` (`_mark`, the only writer of `totalDebt`; NatSpec: "A slash between reports is a loss that waits here on purpose"), `:265-267` (`unlockedSupply = _quoteWithdraw(idle)` on the same stale book), `:282-288` (`_transferIn` → `_allocate` → `_mark`); OZ `ERC4626Upgradeable.deposit` :205-215 (`previewDeposit` **before** `_deposit`) and `_deposit` :273-285 (`_transferIn` then `_mint(shares)`); `ERC7540AsyncRedeem.instantRedeem` :181-186 (`convertToAssets` on the stale book, ungated); `Tranche.slash` :71-95 (moves `Tranche.totalAssets` live, never calls the underwriter).
**Impact:** between a slash and the next `_mark` the Underwriter reports `totalAssets` above the live value and the contract's own `IUnderwriter.debt` NatSpec calls it "an upper bound". Two legs:
- *Exit*: any share holder (no role needed — transferees included) `instantRedeem`s at the stale price and is paid from idle; the entire unrecognised loss `L` is left with whoever stays. PoC: 1,000 book / 814.5 live after a 185.45-token slash; Alice (50%) is paid 500.0 against a fair 407.3 — **92.7 over-paid, taken 1:1 from Bob**, whose 500 shares are worth 314.5 after the keeper reports (fair 407.3). Cumulative exit extraction bound (round-1 verification, still exact): `idle · L / A_stale`.
- *Entry* (new PoC this round): `deposit(d)` mints `d·S/A_stale` shares; with a default tranche set the same call then allocates and `_mark`s, so the book is fresh on return and the depositor's shares are already worth `d·(A_stale − L + d)/(A_stale + d)`. Loss `= d·L/(A_stale + d)` — **not bounded by idle**. PoC: Carol deposits 100 into a 1,000-book/814.5-live vault and holds 83.14 the moment `deposit` returns (a live quote would have minted 122.77 shares, she got 100.0). Without a default tranche the loss is identical, realised at the next report. `mint` has the same shape via `previewMint`.
The vault reports itself covered (`totalAssets` unchanged, `healthiness` of the market is irrelevant to the Underwriter's book) while a depositor loses — Matt's tiebreaker.
**Likelihood:** preconditions: (a) a slash on an allocated tranche (any liquidation; `Slashed`/`Liquidate` events are public); (b) the window until an allocator/keeper action. Exit leg additionally needs idle > 0 (curator buffer, multiple tranches, settled async deallocation — see round-1 verification §7 for reachability in the default-tranche configuration); entry leg needs nothing. No unprivileged way to refresh: `report` is KEEPER, `allocate`/`deallocate*` allocator, `deposit` depositor-role (and the depositor is the one harmed). Attacker capital: none beyond holding shares (exit) — the entry victim is simply the next honest depositor. Cost: gas.
**Exploit path (exit):** 1. Alice 500, Bob 500 in `uw`; allocator puts 500 in tranche T, 500 idle. 2. Borrower draws 250 (max). 3. Price 1.00 → 0.55; LIQUIDATOR repays 100 → 102 USD = 185.45 tokens slashed from T. 4. Alice `instantRedeem(500 shares)` → 500 tokens (fair 407.3). 5. Keeper `report(T)` → Bob's 500 shares = 314.5. Net: Alice +92.7, Bob −92.7.
**Exploit path (entry):** 1–3 as above with everything allocated (default tranche). 4. Carol `deposit(100)`: `previewDeposit` on 1,000 book → 100 shares; `_transferIn` → `_allocate` → `_mark` writes 914.5; `_mint(100)`. 5. `convertToAssets(100 shares) = 83.14`. Net: Carol −16.86, split pro rata to Alice and Bob.
**Proof:** `audit/v3/tests/scratch/C/C2_StaleMark.t.sol` — four fail on HEAD:
```
[FAIL: exiting holder must not be paid above the live share price: 499999999999999998500 > 407272727272727271599] test_P4_exitAtStaleMarkAfterSlash()
  tokens slashed from tranche0:       185454545454545454545
  underwriter totalAssets (stale):    999999999999999999000
  underwriter live valuation:         814545454545454544826
  alice fair:                         407272727272727271598
  alice paid:                         499999999999999998500
  alice over-paid:                    92727272727272726902
  bob fair:                           407272727272727272413
  bob after report:                   314545454545454545697
  bob loss transferred to alice:      92727272727272726716
[FAIL: unadmitted transferee must not be paid above the live share price: 499999999999999998500 > 407272727272727271599] test_P4_exitNeedsNoRole()
[FAIL: a depositor must not lose value inside the deposit that refreshes the book: 83140495867768595043 < 100000000000000000000] test_P4_entryOverpaysInSameTx()
  book before carol (stale):           999999999999999999000
  live position before carol:          814545454545454544640
  carol shares minted (stale quote):   100000000000000000200
  carol shares at a live quote:       122767857142857143102
  carol value right after deposit:    83140495867768595042
  carol immediate loss:               16859504132231404958
  book after carol (fresh):           914545454545454544640
[FAIL: a depositor must not overpay against a stale book: 83140495867768595043 < 100000000000000000000] test_P4_entryOverpaysWithoutDefaultTranche()
```
The liquidation is real (`LIQUIDATOR` role, `market.liquidate` → `Tranche.slash`); the only pranks are the victim/attacker calling their own `instantRedeem`/`deposit`.
**Recommendation:** mark before pricing on every entry and exit. Override `deposit`, `mint`, `instantRedeem`, `instantWithdraw`, `requestRedeem`, `redeem(id,…)`, `withdraw(id,…)` (and the 3-arg pair) in `Underwriter` to first `_mark(t)` for every `t` in `_registeredTranches ∪ {t : debt[t] > 0}`; an `_onWithdraw` hook is too late because OZ prices before `_withdraw`. `_mark` needs no oracle (`convertToAssets` only), so a dead feed cannot brick it; gas is linear in tranche count, which the curator bounds. Add a permissionless `mark(address)` for good measure (insufficient alone: the exiter will not call it). Keep `report` for the premium sweep. Second-order: `unlockedSupply` and `maxRedeem` become live too; `test_queueingADeallocationCatchesAnUnseenSlash`-style tests keep passing.
**Invariant broken:** I37 as an *exchange-rate* property — the book is ≥ live (proved below) but every conversion uses the book, so equality at conversion time is what matters. Suggested statement for the invariant suite: "`Underwriter.totalDebt == Σ_t convertToAssets(balanceOf(uw)+queuedShares[t])` at the moment any share is minted or burned".

### [LOW] C-3 A killed tranche holding dust still takes its full premium weight; a 0.5-token dead senior out-earns a 1,000-token live junior 19:1 (I39)
**Location:** `contracts/cap/market/BaseMarket.sol:482-485` (`_earnsPremium`: `stakedSupply() > 0 && totalCapital() > 0`), `:435-475` (`_chargePremium`: senior gets `remaining`, i.e. its own weight plus every skipped junior's), `Tranche.sol:86-91` (`killed` blocks deposits only), `:177-181` (`totalCapital` floors: 1 wei of an 18-dec asset at ≥ $1 is `≥ 1` wei USD).
**Impact:** after a liquidation retires the senior (below 1% of par), its survivors — who now back almost nothing — keep receiving `weight_0 + Σ skipped` of every underwriter premium. PoC: senior killed to 0.5e18, junior 1,000e18 live, 400 borrowed for 30 days: senior 6.298 cUSD, junior 0.331 cUSD (weights 0.95/0.05). Loss is premium, not principal, borne by the live tranche's depositors; it persists until the market owner (a third party) calls `setTrancheWeights` — nothing forces that. Eligibility floor is price/decimals dependent: 1 wei of an 18-dec asset at $1 is eligible (`totalCapital == 1`), at $0.50 it is not (`0`); 1 wei of a 6-dec asset at $1 is `1e12` wei USD.
**Likelihood:** any liquidation that kills a tranche; no attacker needed. The market owner can also be a beneficiary (owner-held dust senior) but need not act for the misallocation to occur.
**Exploit path:** n/a (state reached by ordinary liquidation).
**Proof:** `C4_Slash.t.sol::test_I39_killedDustSeniorTakesFullPremiumWeight` (passes: `senior (killed, 0.5 capital) premium: 6298198277753663912`, `junior (1000 capital) premium: 331484119881771785`), `::test_I39_oneWeiEligibilityByDecimalsAndPrice`.
**Recommendation:** `_earnsPremium` should return false for `killed()` tranches (the flag exists for exactly "shares survive a wipeout"), or weight premium by `totalCapital` share rather than static weights once a tranche is killed. Second-order: the killed senior's weight then falls to cUSD when no other senior is active — acceptable, that is the documented fallback.
**Invariant broken:** I39 holds as stated (reported because it holds).

### [LOW] C-4 `removeTranche` strands all later premium on the underwriter's remaining position until the tranche is re-added (P17)
**Location:** `contracts/cap/Underwriter.sol:103-116` (`removeTranche`: `_report` only if `debt > 0`, never `optOut`, shares stay), `:299-308` (`_report` reverts `NotRegisteredTranche`), `PremiumVesting.sol:142-155` (`claim` is `msg.sender`-keyed; the Underwriter calls it only from `_report`).
**Impact:** after removal the underwriter is still opted in with its full balance, so it keeps earning inside the tranche, but no code path claims: `report` refuses, `deallocate` only banks the entitlement into `pending[uw]` (`_update` checkpoint, PremiumVesting.sol:206-210). PoC: 6.63 cUSD claimed at removal, a further 9.01 cUSD accrues and is unreachable; `deallocate` of the unlocked 403 shares moves nothing; `addTranche` + `report` recovers all of it. Nothing is burned — the cUSD sits in the tranche — but underwriter depositors who exit in between forfeit their share of it to whoever remains at the eventual re-add.
**Likelihood:** any curator that removes a tranche with a position (the documented flow, `IUnderwriter.deallocate` NatSpec: "Tranches can be removed from registration and still deallocated").
**Proof:** `C5_Premium.t.sol::test_P17_removeTrancheStrandsSubsequentPremiumUntilReAdded` (passes; numbers above).
**Recommendation:** `removeTranche` should `IPremiumVesting(_tranche).optOut()` after the final `_report` (so nothing accrues to a position the vault will not sweep), or `_report` should accept any tranche with `debt[t] > 0 || balanceOf > 0`. Second-order: with `optOut` the position no longer dilutes the remaining stakers of that tranche, which is the correct economics for capital that is leaving.
**Invariant broken:** none listed; implied: "every cUSD a tranche credits to the Underwriter is claimable by some Underwriter code path".

### [LOW] C-5 Opt-in is forfeiture by default, and a senior tranche with nobody opted in silently redirects its 95% share of underwriter premium to cUSD stakers (P18)
**Location:** `contracts/utils/PremiumVesting.sol:114-123` (`optIn` explicit, per account), `:232-246` (`_accrue` divides by `staked` only; zero freezes), `BaseMarket.sol:446-474` (`seniorActive == false` ⇒ `fundCreditBacked(remaining)`), `Stablecoin.sol:83-86`.
**Impact:** three classes earn nothing unless they act: direct tranche depositors who do not `optIn` on the tranche; underwriter depositors who do not `optIn` on the Underwriter (PoC: Alice 6.63 cUSD, Carol 0 for identical capital and identical slash exposure); and every holder of a senior tranche whose `stakedSupply == 0` — that tranche's weight plus all skipped juniors' goes to the stablecoin (PoC: 1,000-token senior with no opt-in earns 0; 7.87 of 8.29 cUSD goes to cUSD stakers, the 100-token junior gets 0.41). The behaviour is stated only in `BaseMarket._chargePremium` NatSpec ("or vest on the stablecoin") and `PremiumVesting` ("Only opted-in balances earn"); there is no user-facing documentation, and the test helpers (`_fundTranche`, `_fundUnderwriter`) always opt in, so the default path is never exercised by the suite. The re-add path is fine: `optIn` is idempotent and `removeTranche` never opts out, so an Underwriter's position stays opted in across remove/re-add (`test_P18_reAddDoesNotForfeit`).
**Likelihood:** every integration that forgets one call; economically it transfers the underwriting premium from the parties bearing the slash risk to parties bearing none (cUSD holders, or opted-in co-holders).
**Proof:** `C5_Premium.t.sol::test_P18_seniorWithNoOptInSendsAllUnderwriterPremiumToCUSD`, `::test_P18_underwriterDepositorWithoutOptInEarnsNothing` (both pass; numbers above).
**Recommendation:** opt in on mint for EOA receivers (or default-in with an explicit `optOut` for integrators that cannot claim), and document the senior-idle → cUSD redirect prominently. Second-order: default-in raises `staked` for every holder; `_update` already checkpoints both sides, so no accounting change beyond the `optedIn` default.
**Invariant broken:** none.

### [INFORMATIONAL] C-6 Foreign `requestRedeem(…, controller = underwriter)` is refused by `finalizeDeallocateAsync`, ignored by `_mark`, but sits ahead of the underwriter in the FIFO watermark and inflates `maxRedeem(underwriter)`
**Location:** `ERC7540AsyncRedeem.sol:72-91` (any owner may name any controller), `:337-356` (`_claimableShares` watermark), `:226-242` (`maxRedeem` sums all controller requests), `Underwriter.sol:165-180` (`finalizeDeallocateAsync` refuses `shares > queuedRequest[t][id]`), `:187-190` (`_mark` counts only `balanceOf + queuedShares`).
**Impact:** verified: `UnknownQueuedRequest` on the foreign id; book unchanged. Distortion: a request injected *before* the underwriter's own occupies the first `X` of unlocked supply, so the underwriter's request is claimable only for `unlocked − X` (PoC: 285.7 of 400 with 585.7 unlocked and a 300-share injection); the injected shares are stuck forever (only the controller can claim or `transferRequest`, and the Underwriter has no code path for either), so the griefer pays `X` shares outright for a delay bounded by the borrower's repayment. `maxRedeem(uw)` reads 585.7 but nothing in the Underwriter consumes it. Ties to P2 (WS-B): the same injection pattern is what floods `controllerRequests` for the O(n²) sort.
**Proof:** `C6_InjectedRequest.t.sol` (passes; numbers above).
**Recommendation:** none required for accounting; for liveness, allow the Underwriter (or anyone) to `transferRequest` an unrecognised id back to its `owner`, or have `requestRedeem` require `controller == owner || isOperator(controller, msg.sender)`.

### [INFORMATIONAL] C-7 No restaking code exists; the "correlated restaked collateral" premise of the brief does not apply to the contracts
**Location:** `contracts/` (grep for Symbiotic/EigenLayer/delegat/restak → nothing); collateral is plain ERC-6909 balances in `Vault.sol`, moved by `Tranche.slash` → `IVault.withdraw` (:93).
**Impact:** the round-3 brief's assumption that underwriter collateral is restaked and correlated across protocols has no on-chain counterpart. Slashing is synchronous, local, and final: `Tranche.slash` burns the Vault balance in the liquidation transaction. A future adapter (a Vault balance backed by a Symbiotic/EigenLayer position) would have to guarantee: (a) the balance `Tranche.totalAssets()` reads is *already* redeemable at the moment `slash` runs — no external veto or delay between `IVault.withdraw` and the liquidator receiving tokens; (b) an external slash of the same stake must reduce `Tranche.totalAssets()` before this protocol's health check, otherwise `healthiness` overstates coverage in exactly the C-2 pattern one level up; (c) the operator set for that balance stays as narrow as C-1's fix requires.
**Recommendation:** state in the trust model that collateral is unencumbered ERC-6909; if a restaking adapter is planned, the ordering guarantees above are the acceptance criteria.

### [INFORMATIONAL] C-8 A killed default tranche jams every Underwriter deposit until the curator repoints it
**Location:** `Underwriter.sol:282-288` (`_transferIn` → `_allocate(defaultTranche)`), `Tranche.sol:130-137` (`maxDeposit == 0` when killed → OZ `ERC4626ExceededMaxDeposit`).
**Impact:** deposits revert; exits unaffected. `removeTranche` clears the default (:111-114). Proof: `C4_Slash.t.sol::test_killedDefaultTrancheBlocksUnderwriterDeposits`.
**Recommendation:** in `_transferIn`, skip allocation when `ITranche(defaultTranche).killed()` (hold idle instead), matching what an unset default already does.

### [INFORMATIONAL] C-9 `createTranche` is the market owner's one coverage lever: a funded appended junior unlocks every senior one-for-one (numbers for P14; I27 otherwise holds)
**Location:** `Registry.sol:177-199` (`createTranche`, owner-gated by inline `hasRole`, appends most-junior), `BaseMarket.sol:270-289` (`lockedValue` subtracts junior `totalCapital`), `:390-406` (`_setTranches`: REGISTRY-only via `Registry.sol:435-437`, requires healthy).
**Impact:** with 1,000 in the senior and 500 of debt, `lockedValue(senior) = ceil(500/0.7) = 714.285714285714285715e18` and 285.71 shares are unlocked. After the owner appends a junior and a party funds it with 720, `lockedValue(senior) = 0`, the underwriter allocator `deallocate`s all 1,000 while the 500 stays outstanding; health `1.152e27`, remaining capital 720 ≥ 714.29. Consistent with the design (juniors are first loss and lock first); the protocol never goes below `D/(lt−buffer)`. It becomes an exploit only if the junior's `totalCapital` can be inflated — GOVERNOR-listed feed for a thin asset (lead, P14) — or slashed elsewhere first (C-7(b)). `_setTranches` reverting `Unhealthy` also means a fresh junior cannot be appended to *rescue* an unhealthy market (only deposits into existing tranches or repayment can) — a liveness limitation, not a trap: the Registry never calls it on its own.
**Proof:** `C3_Waterfall.t.sol::test_lockedValue_appendedJuniorUnlocksSenior`, `::test_createTranche_revertsWhileUnhealthy`, `::test_I27_ownerCannotChangeMembershipOrOrder`, `::test_I27_trancheCannotBeSharedAcrossMarkets` (all pass).
**Recommendation:** for the lead's P14 write-up. Independently: require `_weights[existing.length] == 0` or a GOVERNOR co-sign when `totalDebt() > 0` if appending while indebted is not meant to be an owner power.

### [INFORMATIONAL] C-10 Slash edge cases verified (no finding)
- Full wipe (`total − assets == 0`): `killed` latches, shares survive at `convertToAssets == 0`, the Underwriter `_mark`s to 0, `deallocate` burns the dead shares for nothing when the tranche is unlocked, `removeTranche` works. With debt and juniors not covering it, the worthless senior shares are locked (`lockedShares` quoted against `A + 1 = 1`), harmless in the book, and free once the debt drops under the juniors' cover (`C4_Slash.t.sol::test_slash_fullWipe_*`).
- Dead feed: `Tranche.slash` and `BaseMarket.totalCapital` both revert `InvalidPrice`, so one dead feed blocks the whole waterfall and every health read (P11, WS-D) — recorded here only as the coverage-side consequence.

## Invariants
- **I25 — broken** (C-1). `∀ o : Vault.isOperator(underwriter, o) ⇒ Registry-deployed tranche with `asset() == underwriter.asset()``. Nothing asserts it; `addTranche` accepts any contract with an `optIn()`.
- **I27 — holds.** `setTranches` is REGISTRY-only, `setTrancheWeights` preserves addresses and order, `createTranche` appends, `_setTranches` rejects foreign-market tranches and duplicates; no protocol role can call `setTranches` (`canCall` false for the GUARDIAN/GOVERNOR/KEEPER holder). The owner's residual lever is C-9.
- **I37 — holds with two stated caveats** (`C7_I37Invariant.t.sol`, 2 invariants, ~100k handler calls, 0 reverts):
  `book := idle + totalDebt`, `live := idle + Σ_t convertToAssets(balanceOf(uw)+queuedShares[t])`.
  (a) `book + g ≥ live` where `g` = number of third-party tranche deposits/instant-redeems since the last report (each floors on the mover's side and gifts ≤ 1 wei to remaining holders — the first run without the tolerance failed by exactly 1 wei). (b) `book == live` after `report` on every tranche. (c) Excluded: gratuitous ERC-6909 donations to a tranche (`vault.transfer(tranche, asset, x)` by anyone) make the book stale-*low* (`test_I37_donationIsTheOnlyStaleLowPath`: book 500, live 600) — a gain for holders, never a loss. Direction of every ordinary movement is therefore book ≥ live, which is what makes C-2 a one-way transfer rather than symmetric MEV.
- **I39 — holds** (C-3): killed + dust + staked ⇒ full weight.
- New, implied by code and worth a handler: **I41** `Underwriter.totalDebt == Σ_t convertToAssets(balanceOf(uw)+queuedShares[t])` at every `_mint`/`_burn` of Underwriter shares (fails today; C-2). **I42** every cUSD credited to the Underwriter inside a tranche is reachable by an Underwriter code path (fails after `removeTranche`; C-4).

## Hypotheses
- **P1 — CONFIRMED (High).** Reproduced on production wiring from a single WHITELISTED grant; 100% of idle plus everything the market has not locked; HEAD only added NatSpec.
- **P4 — CONFIRMED (High), both legs.** Exit over-payment `min(f·L, idle·L/A)`; entry loss `d·L/(A_stale+d)` realised inside the same `deposit` when a default tranche is set, and not bounded by idle. No unprivileged re-mark exists. Book can only be stale-high through normal activity (I37).
- **P17 — CONFIRMED (Low).** Premium after `removeTranche` is stranded, recoverable only by `addTranche` + `report`.
- **P18 — CONFIRMED (Low).** Default is forfeiture; senior with `stakedSupply == 0` redirects 95% to cUSD; documented only in NatSpec; re-add path does not forfeit.

## Appendix: gas & style
- `BaseMarket.lockedValue` (:279-288): the no-`break` path (tranche not in the array) is unreachable on HEAD but silently returns the most-senior formula; a comment or an explicit revert would make that visible.
- `Underwriter.deallocate` (:137-140) reads `ITranche(tranche).balanceOf(address(this))` and then `instantUnlockedSupply()` (an oracle walk) even when `shares == 0`; short-circuit on `shares == 0` keeps the "mark is fresh" postcondition and saves the walk.
- `Underwriter.removeTranche` (:104) skips `_report` when `debt == 0` but not when `balanceOf > 0 && debt == 0` (possible after a full wipe): harmless, but `optOut` (C-4) would make the branch uniform.
- `Tranche.slash` (:88): `(total - assets) * KILL_RATIO` can overflow only for `total > 2^256/100`; fine for any real asset, worth a comment since `total` is user-controlled.
- `BaseMarket._chargePremium` (:448-462) calls `_earnsPremium` (two external reads incl. an oracle) per tranche on every borrow/repay/liquidate; caching `totalCapital` per tranche from the health walk in the same call would halve oracle reads.
