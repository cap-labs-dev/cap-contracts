# Workstream B — External callers & composability

> **Post-verification status (lead, 2026-09-14):** B-1 **Medium confirmed, low end** (`verify/B-1.md`: batchable recovery, ungated share transfers; integrators without a 4-arg path carry the Medium). Report ID R3-M4. Lows unchanged.


Target: `cap-network` @ `a843c1d`. Owner of P2, P3, P19, P20, the permissionless-entrypoint sweep and I33.
Every number below comes from `audit/v3/tests/scratch/B/*` run as
`FOUNDRY_TEST=audit/v3/tests/scratch/B forge test --match-path 'audit/v3/tests/scratch/B/*' -vv`
(18-decimal `CapDeployer`, real `Oracle` + `ChainlinkAdapter`). Files read end to end:
`ERC7540AsyncRedeem.sol`, `ERC7540Operator.sol`, `Vault.sol`, `PremiumVesting.sol`, `Stablecoin.sol`,
`Tranche.sol`, `Underwriter.sol`, `Wrapper.sol`, `BaseMarket.sol`, `FloatingMarket.sol`, `FixedMarket.sol`,
`InterestRateModel.sol`, `Oracle.sol`, `ChainlinkAdapter.sol`, `Registry.sol`, `DeadShares.sol`, `AssetId.sol`,
`test/shared/mocks/MockReentrantERC20.sol`.

Final run (`scratchpad/B_final.log`): `Ran 6 test suites in 88.75s: 35 tests passed, 1 failed` — the failure is
`invariant_I34_selfBalanceCoversQueueAndRemaining` (B-3, replayed from the persisted shrunk sequence); every
handler invariant ran `runs: 80, calls: 24000, reverts: 0`.

Summary: one Medium (P2, request-flood DoS of the standard ERC-4626/7540 claim path, confirmed with a gas table),
three Lows (an I35 gap in `recognizeBadDebtInReserve` found by the Stablecoin handler fuzz; a 1-wei I34 leak
where `Stablecoin.claim` pays over-attributed premium out of the redemption escrow; `Vault.deposit` minting the
nominal amount so a fee-on-transfer collateral bricks liquidation). P3 (out-of-order settlement, H-2 regression)
and P19 (reentrancy) are **refuted** with 24k-call handler fuzzes and a hostile-recipient probe respectively;
the mid-flight state is pessimistic in every direction that matters. P20's oracle half is refuted; its vault half
is the Low above.

---

## 1. Permissionless-entrypoint sweep

Every function callable by any address on an in-scope contract, with what it moves, its boundary behaviour,
whether a contract caller changes anything, and same-block repetition / timing. `restricted` functions are
listed only where the gate is inline (`createTranche`, `slash`). SAFE = no finding after testing the boundary.

| Contract.function | State moved | 0 / 1 / max / sentinel | From a contract | Repeated in one block | Verdict |
|---|---|---|---|---|---|
| `Vault.deposit(asset, amount, to)` | `safeTransferFrom(msg.sender)` then `_mint(to, id(asset), amount)` (L34-37) | `amount=0` mints 0; `asset` with no code reverts in `SafeERC20`; `asset=vault` reverts (no ERC-20 selector) | Hook token: callback fires between transfer and mint; the not-yet-minted balance cannot be withdrawn (`test_P19_vaultDepositHook_isCEI`) | idempotent | **FINDING B-4**: mints `amount`, not the received delta — fee-on-transfer / negative-rebasing collateral makes the id insolvent and `Tranche.slash` revert |
| `Vault.withdraw(asset, amount, to)` | `_burn(msg.sender)` then `safeTransfer(to)` (L40-43) | `amount=0` fine; `to=0` reverts in most tokens | callback to `to` after burn: CEI | — | SAFE |
| `Vault.transfer/transferFrom` (both 4-arg and ERC-6909) | 6909 balances; operator can move **every** id of the owner | max reverts on balance | — | — | SAFE for the Vault; the "operator moves every id" is P1 [C] |
| `Stablecoin.deposit/mint` | par; `_deposit` → `IRM.updateLiquidityRate` after mint (L301-304) | `deposit(0)` mints 0 and pokes the IRM; at 6-dec `previewDeposit` floors | — | dilutes utilization for the EMA within the block (P6 [lead]) | SAFE (rate side is P6) |
| `Stablecoin.fund(premium)` | pulls USDC, mints cUSD **to itself**, `remainder += shares` (L77-80) | `fund(0)` = a free `_accrue()` + `updateLiquidityRate()` | — | dominated by `deposit`-and-hold as a utilization lever | SAFE; note the self-balance now mixes escrow and pot → B-3 |
| `Stablecoin.coverBadDebt(amount)` | burns caller's cUSD, `badDebt -= min` (L170-181) | `NoBadDebt` when 0; `amount=0` burns 0 and emits | — | — | SAFE (donation) |
| `requestRedeem(shares, controller, owner)` | escrows `shares` to the vault, `controllerRequests[controller].add` — **controller is any address** (L72-91) | `shares=0` reverts; `controller=0` reverts; `controller=address(this)`/DeadShares strands the shares forever (self-harm, see App.) | — | unbounded per controller | **FINDING B-1** (flood) |
| `transferRequest(id, to)` | moves the id between sets; no consent from `to` (L94-108) | `to=0` reverts; `to=from` no-op; dead id reverts | — | unbounded | **FINDING B-1** (reverse-order worst case for `_sortIds`) |
| `redeem/withdraw` 4-arg | one id, one `unlockedSupply()` (L117-142) | `shares=0` on any id: `_consumeRequest(controller, 0, id)` is a no-op on foreign ids, emits `Withdraw(0)` and pokes the IRM (App.) | `_checkController` — allowance does not stand in | O(1); flat 96k (tranche) / 72k (cUSD) under flood | SAFE |
| `redeem/withdraw` 3-arg | FIFO over **all** of the controller's ids, `unlockedSupply()` per id twice (`maxRedeem` + `_claimFifo`), O(n²) `_sortIds` (L148-178, L372-423) | `0` returns 0; `IncompleteClaim` unreachable (live watermark only rises mid-loop, `remainingUnlocked` bounds) | — | super-linear | **FINDING B-1** |
| `instantRedeem/instantWithdraw` | `_withdraw`, capped by `instantUnlockedSupply` (L181-200) | `0` fine | allowance may stand in (documented) | — | SAFE |
| `maxRedeem/maxWithdraw` | view, O(n) `unlockedSupply()` | early-return once `≥ unlocked` (never under a dust flood) | — | — | **FINDING B-1** (view OOG at RPC caps) |
| `PremiumVesting.optIn/optOut/claim` | `staked`, checkpoints; `claim` clamps to `balanceOf(this)` of the premium token (L114-155) | `claim` with 0 returns 0; opt-in by `address(this)`/DeadShares refused | — | same-block opt-in captures 0; one block captures `12/43200` of the pot × share (§6) | SAFE; on the Stablecoin the clamp includes the escrow → **B-3** |
| `FloatingMarket.repay(amount)` | anyone repays anyone; `_chargePremium` first (L75-80) | `0` → `InvalidAmount`; dust → `InvalidScaledAmount` | `nonReentrant` (transient) | same-block second call: index frozen, no accrual | SAFE |
| `FloatingMarket.chargePremium()` | mints premium to tranches / cUSD (L99-101) | early-return same block | `nonReentrant` | — | SAFE here; unbacked premium on `unrecoverableDebt` is P9 [D] |
| `FixedMarket.repay(id, amount)` | anyone repays any loan (L127-134) | `id ≥ loanCount` → `LoanNotFound`; `0` → `InvalidAmount` | `nonReentrant` | — | SAFE |
| `IRM.updateLiquidityRate()` | folds EMA, snapshots index, re-reads live utilization (L100-102, L242-248) | repeated same block: `elapsed=0`, only `observed*` refreshed | — | every stablecoin state change already calls it; rate is always from live state | SAFE |
| `Wrapper.deposit/mint/withdraw/redeem` | claims cUSD premium first, then standard 4626 (L81-99) | `deposit(0)` on an empty wrapper reverts `DepositBelowSeed` | — | — | SAFE |
| `Registry.createTranche(market, asset, weights)` | inline `hasRole(marketOwnerRole)` (L173-198), no execution delay | any oracle-priced asset | — | — | gate SAFE; the delay bypass is P15 [E] |
| `Tranche.slash(value, recipient)` | `msg.sender == market` (L72) | `total==0` → 0; floor-to-zero → 0 | recipient hook: §4 | — | gate SAFE |

---

## 2. Findings

### [MEDIUM] B-1 — Anyone can flood a controller with dust redemption requests; the standard ERC-4626/7540 claim path (`maxRedeem`, 3-arg `redeem`/`withdraw`) then costs more than a block, and the victim can only shed the requests one at a time
**Location:** `contracts/ERC7540/ERC7540AsyncRedeem.sol:72-91` (`requestRedeem` — `_controller` is unconstrained), `:94-108` (`transferRequest` — no consent from `_to`), `:226-242` (`maxRedeem` — one `unlockedSupply()` per id), `:372-406` (`_claimFifo` — one `unlockedSupply()` per id again, one `_consumeRequest` per dust id), `:410-423` (`_sortIds` — insertion sort, O(n²) on a descending set); `contracts/cap/Tranche.sol:163-174` (`unlockedSupply` → `lockedValue` walk + oracle per junior).
**Impact:** A targeted controller's ERC-4626 claim path is denied. On a 2-tranche senior the 3-arg `redeem`/`withdraw` cross 30M gas at **n ≈ 290** dust requests (4 tranches: n ≈ 248; cUSD: n ≈ 350); `maxRedeem`/`maxWithdraw` — the views every 4626 integrator calls before claiming — cross 30M at n ≈ 930 (4 tranches) and exceed a 50M `eth_call` cap around n ≈ 1,500. `controllerRequests` has no bound anywhere. The protocol's own actors are unaffected (`Underwriter.finalizeDeallocateAsync` uses the 4-arg claim, `Wrapper` never claims), so this is a griefing DoS of external users and integrators of cUSD, tranche and underwriter shares, not a fund loss. The victim keeps the 4-arg escape (flat 96k / 72k gas) but must shed each gift individually: 73k per `transferRequest` or 96k per 4-arg zero-claim — 42–56 % of what the attacker paid per id.
**Likelihood:** No role on cUSD (deposit is permissionless; 1 wei of cUSD per request — at 6-dec USDC that is 1e-12 USDC). On a tranche/underwriter the attacker needs n wei of shares (any depositor, or shares bought/transferred). Cost 172k gas per id with the reverse-order trick (121k `requestRedeem` + 51k `transferRequest`), 121k without it (direct `requestRedeem(1, victim, attacker)`, ascending ids, sort linear — crosses 30M at n ≈ 650 instead of 290, so the trick is ~1.6× more efficient). Reaching the 30M crossing costs the attacker ≈ 50M gas ≈ 0.05 ETH at 1 gwei on mainnet, cents on the L2/alt-L1 targets in `foundry.toml` (`monad`, `tempo`, `megaeth`, `katana`).
**Exploit path:** 1. Attacker holds 1 wei × n of the victim's share token. 2. n × `requestRedeem(1, attacker, attacker)` → ids `k+1 … k+n`. 3. `transferRequest(k+n → k+1, victim)` in that order → `controllerRequests[victim]` is descending. 4. Victim (or its integrator) calls `maxRedeem(victim)` / `redeem(shares, victim, victim)`: every id costs one `unlockedSupply()` (a `lockedValue` walk with an oracle staticcall per junior) in `maxRedeem` and again in `_claimFifo`, plus a `_consumeRequest` per dust id ahead of the victim's own request in FIFO order, plus n²/2 insertion-sort steps. Net: attacker spends gas + n wei; victim's standard path reverts OOG until it sheds n ids.
**Proof:** `audit/v3/tests/scratch/B/B_P2_RequestFlood.t.sol` (documentary; all pass and print). Gas of the victim's call, dust requests transferred newest-first; `atk/*` is the attacker's per-id cost:

| Target | n | `maxRedeem` | 3-arg `redeem` | 3-arg `withdraw` | 4-arg `redeem` | atk/request | atk/transfer |
|---|---|---|---|---|---|---|---|
| Tranche, 2 tranches | 50 | 992,532 | 2,922,411 | 2,922,528 | 95,671 | 122,365 | 51,729 |
| | 200 | 3,854,159 | 16,987,396 | 16,987,517 | 95,677 | 121,350 | 51,400 |
| | 250 | 4,808,055 | 23,595,901 | 23,596,021 | 95,676 | | |
| | 275 | 5,285,006 | 27,260,186 | 27,260,311 | 95,683 | | |
| | **300** | 5,761,960 | **31,164,493** | **31,164,624** | 95,692 | | |
| | 500 | 9,577,678 | 71,039,740 | 71,039,870 | 95,689 | 121,151 | 51,334 |
| | 1000 | 19,117,656 | 237,934,012 | 237,934,144 | 95,693 | 121,083 | 51,312 |
| Tranche, 4 tranches | 50 | 1,683,924 | 4,305,195 | 4,305,312 | 122,264 | | |
| | 200 | 6,539,951 | 22,358,980 | 22,359,101 | 122,269 | | |
| | 225 | 7,349,298 | 26,208,021 | 26,208,142 | 122,268 | | |
| | **250** | 8,158,647 | **30,297,085** | **30,297,202** | 122,274 | | |
| | 500 | 16,252,270 | 84,388,924 | 84,389,054 | 122,282 | | |
| | 900 | 29,204,146 | | | | | |
| | 950 | **30,823,000** | | | | | |
| | 1000 | 32,440,248 | 264,579,196 | 264,579,329 | 122,286 | | |
| Stablecoin (cUSD) | 50 | 273,046 | 1,493,682 | 1,493,698 | 71,783 | 122,179 | 51,164 |
| | 200 | 1,049,373 | 11,427,965 | 11,427,982 | 71,788 | | |
| | 325 | 1,696,380 | 26,307,143 | 26,307,159 | 71,618 | | |
| | **350** | 1,825,788 | **30,003,048** | **30,003,065** | 71,627 | | |
| | 500 | 2,602,292 | 57,218,908 | 57,218,924 | 71,801 | 120,929 | 50,769 |
| | 1000 | 5,191,270 | 210,344,179 | 210,344,195 | 71,826 | | |
| Tranche k=2, **direct** flood (no transfer, ascending) | 300 / 400 / 500 | | 13,865,790 / 18,436,545 / 23,007,652 | | | 121,289 | — |

Shedding: `victim transferRequest (shed one) gas: 72893`, `victim 4-arg claim of one dust request gas: 95735`.
Raw log lines are in `B_P2_RequestFlood.t.sol` output (`TRANCHE k=… n=… maxRedeem=… redeem3=… …`).
**Recommendation:** Three independent fixes; do the first two at minimum. (1) Compute `unlockedSupply()` once per call and pass it into `_claimableShares` (it is already tracked as `remainingUnlocked` in `_claimFifo`; `maxRedeem` already has `unlocked`) — cuts the per-id cost to a few SLOADs and removes the oracle walk from the loop; second-order: none, the loop's live re-read can only rise mid-loop and is already bounded. (2) Require consent to become a controller of someone else's request: in `requestRedeem`, `if (_controller != _owner && !isOperator(_controller, msg.sender)) revert`; in `transferRequest`, `if (!isOperator(_to, msg.sender)) revert` — ERC-7540 lets a *controller* be distinct from the owner, it does not require that anyone may impose the role on a stranger. (3) Replace the memory insertion sort with an ordered structure kept at request time (ids are monotonic, so appending to a per-controller array and removing by swap-with-last is enough if the 3-arg path walks a snapshot sorted once with an O(n log n) sort, or simply cap the 3-arg path to the K oldest ids and let callers pass an explicit id list). (1)+(2) together make the flood impossible for strangers and cheap for consenting ones.
**Invariant broken:** none listed; new: `controllerRequests[c].length` is bounded by actions `c` consented to.

### [LOW] B-2 — `recognizeBadDebtInReserve` bounds `badDebt` by `totalSupply`, not by the reserve-backed supply; after an over-recognition an ordinary borrower repay takes `totalSupply` below `badDebt` and every conversion reverts (I35)
**Location:** `contracts/cap/Stablecoin.sol:152-156` (`recognizeBadDebtInReserve`), `:195-197` (`backing()` = `totalSupply() - badDebt`), consumers `:200-202`, `:236-287`; `:94-99` (`burnCreditBacked`, reached by the permissionless `FloatingMarket.repay` / `FixedMarket.repay`).
**Impact:** The check `badDebt > totalSupply()` admits `badDebt + creditBackedSupply > totalSupply` — a reserve loss larger than the reserve itself (plan invariant I35 is violated by the GUARDIAN alone). From that state any `burnCreditBacked` (a repay, a liquidation) can leave `totalSupply < badDebt`; `backing()` then panics (0x11) inside `totalAssets`, `convertToAssets/Shares`, `maxWithdraw`, `previewMint`, `quoteWithdraw`, every `redeem`/`withdraw`/`instantRedeem`, `Wrapper.totalAssets` and `Underwriter._mark` of nothing (it is cUSD-priced only via the tranche). `coverBadDebt` cannot repair it (burns supply and `badDebt` together); a fresh `deposit` (par mint) or a borrow does. No theft; a temporary halt of every exit from cUSD and stcUSD.
**Likelihood:** Requires a GUARDIAN input error (recognising more reserve loss than the reserve-backed supply), then any repay. Found by the Stablecoin handler fuzz before I bounded the guardian op to I35: shrunk sequence `request, withdraw3Max, mintCredit, badDebtReserve ×4, mintCredit, instantRedeem, badDebtReserve` → `[FAIL: I35: 2595179296556057490654 > 2456460574648742364091]`, and with one more `burnCredit`: `[FAIL: panic: arithmetic underflow or overflow (0x11)]` in `invariant_unlockedWithinReserve` (`quoteWithdraw` → `backing`).
**Exploit path:** 1. Reserve-backed 100, credit-backed 900 (supply 1000). 2. GUARDIAN `recognizeBadDebtInReserve(500)` — accepted (500 ≤ 1000). 3. Borrower repays 600 → `totalSupply = 400 < badDebt = 500`. 4. `totalAssets()`, `convertToAssets(1e18)`, `maxWithdraw`, `instantRedeem` all revert until someone mints ≥ 100 cUSD.
**Proof:** `B_P3_StablecoinQueueFuzz.t.sol::B_I35_GuardianOverRecognition::test_I35_overRecognitionThenRepayBricksConversions` — passes as written (it *asserts* the reverts). Handler run with the unbounded guardian op: `Encountered 7 failing tests … [FAIL: I35: …] … [FAIL: panic: arithmetic underflow or overflow (0x11)]` (first run log, before the handler was bounded).
**Recommendation:** `if (badDebt + creditBackedSupply > totalSupply()) revert BadDebtExceedsSupply();` in `recognizeBadDebtInReserve` (and keep the existing check in `recognizeBadDebtInCredit`, where `creditBackedSupply -= _amount` already enforces it implicitly). Second-order: none; the reserve can never legitimately lose more than the reserve-backed supply.
**Invariant broken:** I35.

### [LOW] B-3 — On the Stablecoin, `PremiumVesting.claim` clamps to `balanceOf(this)`, which is the redemption escrow plus the premium pot; floor-asymmetric attribution pays up to 1 wei per checkpoint out of the escrow (I34)
**Location:** `contracts/utils/PremiumVesting.sol:142-155` (`claim` — `held = IERC20(token).balanceOf(address(this))`), `:253-259` (`_checkpoint` — `floor(ps·b) − floor(ps_old·b)` per segment), `:266-276`; `contracts/cap/Stablecoin.sol:62` (`stablecoin = address(this)` — pot and escrow share one balance), `:77-80`.
**Impact:** The comment on `claim` already says entitlements can sum past the pot; on `Tranche`/`Underwriter` the pot (cUSD) and the escrow (own shares) are different tokens so the clamp is exact. On the Stablecoin they are the same token: an over-attributed wei is paid from the escrow, `balanceOf(stablecoin) = redemptionQueue() + remaining() − 1`, and once the pot is fully vested the last queued claimant's `_burn(address(this), shares)` reverts for its final wei. Dust; liveness of one wei of one request.
**Likelihood:** Organic; opt-in/opt-out churn with premium arriving between checkpoints. Found in 24k handler calls; shrunk to 16 steps.
**Proof:** `B_P3_StablecoinQueueFuzz.t.sol` (seed `0x27237cfe823fda17456aaed849620af5b04c9641b283cf3e9c9703998997f3fb`):
```
[FAIL: I34: self balance < queue + remaining: 32670587820543852838 < 32670587820543852839]
  [Sequence] (original: 155, shrunk: 16)
  instantRedeem, fund(6380,11302), fund, request, optIn, warp(916), optIn, deposit, request,
  warp(239485516), fund, fund, claimPremium, warp, claimPremium, claimPremium
```
**Recommendation:** In `Stablecoin`, override the clamp: `held = balanceOf(this) − redemptionQueue()`. Or track the pot separately (`remainder` is already the unvested part; keep a `vestedUnclaimed` counter and clamp to `remainder + vestedUnclaimed`). Second-order: none.
**Invariant broken:** I34 (by 1 wei).

### [LOW] B-4 — `Vault.deposit` credits the requested amount, not the received amount; a fee-on-transfer or negatively-rebasing collateral makes that asset id insolvent and the first full `Tranche.slash` on it reverts the whole liquidation (I12)
**Location:** `contracts/cap/Vault.sol:34-37` (`deposit`), `:40-43` (`withdraw`); consumer `contracts/cap/Tranche.sol:93` (`slash` → `IVault.withdraw`), `contracts/cap/market/BaseMarket.sol:367-373` (waterfall, no try/catch).
**Impact:** Every deposit of such a token leaves the Vault short by the fee; the last withdrawer(s) of that id revert. Because a tranche's `totalAssets()` is its 6909 balance, `slash` asks the Vault for more than it holds on the first full drain and `liquidate` reverts — the market cannot be brought back to health while the junior on that asset is non-empty. Positively-rebasing tokens leave un-claimable excess in the Vault (lost yield, no insolvency).
**Likelihood:** Governance/market-owner choice: the asset must be oracle-priced (GOVERNOR `setSource`) and used in `createTranche`/`createFloatingMarket` (market owner, a third party). No attacker profit: the depositor pays the fee both ways; the harm is to the market's liquidatability.
**Exploit path:** 1. Junior tranche on a 2 %-fee token; LP deposits 100 → 6909 balance 100, Vault holds 98. 2. Debt drawn, collateral price falls, market unhealthy. 3. `liquidate` → junior `slash(306)` → `Vault.withdraw(fee, 100, recipient)` → `safeTransfer` reverts → liquidation reverts.
**Proof:** `B_P20_TokenOracle.t.sol::test_P20_feeOnTransfer_vaultBecomesInsolventForThatAsset` (`I12 broken: 6909 supply 100e18 vs ERC20 on hand 96000000000000000000`; second withdrawer reverts) and `::test_P20_feeOnTransfer_trancheSlashBricksLiquidation` (`liquidate reverted: Vault holds 98000000000000000000 vs tranche 6909 balance 100000000000000000000`). Both pass as written (they `expectRevert`).
**Recommendation:** Mint the balance delta: `uint256 before = token.balanceOf(this); safeTransferFrom; _mint(to, id, token.balanceOf(this) − before)`. Second-order: rebasing tokens are still unsupported (document); a reentrant token could not inflate the delta because the delta is read after the transfer returns.
**Invariant broken:** I12.

---

## 3. P2 detail — who is hurt, what remains

- **Protocol actors:** none. `Underwriter.finalizeDeallocateAsync` (L165-180) claims by id; `deallocate` uses `instantRedeem`; `Wrapper` never claims. A flood of `controllerRequests[underwriter]` on a tranche is inert.
- **External users/integrators** of cUSD, tranche shares and underwriter shares: every ERC-4626 client (`maxRedeem` → `redeem`) and every ERC-7540 client using the 3-arg claim. A flooded cUSD holder cannot exit through the standard interface; they can through `redeem(requestId, …)`.
- **Shedding:** `transferRequest` back requires `controller == victim` — yes, one per tx at 73k; or a zero-cost 4-arg claim at 96k. There is no bulk path.
- **Bound on `controllerRequests`:** none.
- The 3-arg path is also super-linear even for an honest controller with many of its own requests (n² sort); a market maker splitting exits into hundreds of requests would hit the same wall.

## 4. P3 — out-of-order settlement under the new watermark (REFUTED)

Reasoning: `_claimableShares` (L337-356) is `min(clamp(settledQueue + unlocked − queueIndex, 0, balance), unlocked)`, `_claim` (L431-439) reverts when `_shares > unlocked`, and `_claimFifo` (L372-406) tracks `remainingUnlocked` from the initial `unlocked`. An out-of-order consume of window W over-credits earlier windows by |W| positionally, but the per-request clamp and the per-claim check bound every payout by live `unlockedSupply()`, and on `Tranche`/`Underwriter` `unlocked` falls by ≈ the shares taken on every claim, so A cannot be paid after liquidity has gone. Mid-loop in the 3-arg path the live watermark only *rises* (shares burn before assets leave), so `IncompleteClaim` is unreachable and I26 holds.

Handler fuzz (`B_P3_TrancheQueueFuzz.t.sol`, ops `deposit/request/transferRequest/claim4/claim3/borrow/repay/liquidate/movePrice/warp` on a 2-tranche floating market with standing debt, 3 controllers; `fail_on_revert = true`): **80 runs × 300 depth = 24,000 calls, 0 violations** of: each claim ≤ `unlockedSupply()` at claim time; no claim moves a healthy market under `lt`; `redeem(maxRedeem(a))` never reverts (I26); I33a/b/c. Last-run report: `calls 300 claims 38 paidShares 2153785375302475148007 sumUnlockedObserved 58648771920240477780802`.
Stablecoin handler (`B_P3_StablecoinQueueFuzz.t.sol`, adds credit mint/burn, bad-debt recognition inside I35, reserve removal, `fund`, opt-in/out, `withdraw(maxWithdraw)`, `instantRedeem(≤max)`): **24,000 calls**, 0 violations of I26, I33, I35, `unlocked ≤ quote(on-hand)`, no over-claim; the only failure is B-3's 1-wei I34.

P3 is closed. The original H-2 PoC shape (A requests while locked, B later, liquidity rises, B claims first, price falls) now leaves A with `claimable = 0` and `redeem` reverting `ERC4626ExceededMaxRedeem`.

## 5. P19 — reentrancy (REFUTED; mid-flight state is pessimistic)

The only points at which an in-scope contract hands control to a token are `Vault.deposit`/`Vault.withdraw`; `Vault.withdraw` is reached from `Tranche.slash` with a liquidator-chosen `recipient`. cUSD has no hooks (`PremiumVesting._update` is internal), USDC is assumed hookless, `Vault.transfer/transferFrom` (6909) have none.

`B_P19_Reentrancy.t.sol`: a `Probe` recipient that is a senior depositor, junior depositor and underwriter depositor, on a `MockReentrantERC20` collateral; it fires on the junior's payout and re-arms for the senior's. Findings from the logs (all four tests pass):

| Mid-flight observation | junior payout | senior payout | after liquidation |
|---|---|---|---|
| `market.healthiness()` (partial test) | 0.700e27 (pre-liq 0.700) | 0.647e27 | > 1e27 |
| `market.totalDebt()` | pre-liquidation (scaledDebt written last) | same | reduced |
| `senior.unlockedSupply()` / `instantUnlockedSupply()` | 0 / 0 | 0 / 0 | > 0 |
| `senior.instantRedeem(1e18)` | refused (`ExceededMaxRedeem`) | refused | allowed |
| `senior.requestRedeem` then `claimableRedeemRequest` | request accepted, claimable 0 | same | — |
| `market.chargePremium()` | `ReentrancyGuardReentrantCall` | same | — |
| `junior.deposit(10e18)` | refused when killed; when the junior survives, accepted and worth `9999999999999999999` after (priced on the post-slash base; price/share 1.000 → 0.718) | — | — |
| `uw.instantRedeem(50 shares)` | **accepted at 1.000/share**; after `report` the share is 0.9621 | refused (idle exhausted) | — |

Why the senior is always fully locked mid-waterfall: with `debt_old > (sr + jr_old)·lt` and `lockedValue(senior) = debt_old/(lt−b) − jr_new`, at `lt = 0.8, b = 0.1` we get `locked > 1.143·(sr + jr_old) − jr_new > sr`, so `unlockedSupply() = 0` for every unhealthy market until `scaledDebt`/`_totalDebt` is written. The deliberate "write debt last" ordering that `LiquidationReentrancy.t.sol` documents therefore also closes every exit for the recipient. Read-only reentrancy reads *worse* health and *lower* unlocked than the true post-state — an external protocol reading `healthiness()` mid-flight would be too conservative, never too generous.

The one thing the recipient can do is the underwriter exit at the stale mark: it is the H-1/P4 lag (WS-C), which reentrancy merely makes atomic with the slash — the same exit is available to anyone in the same block, so no new power. Reported to WS-C by reference.

`Vault.deposit` hook (`test_P19_vaultDepositHook_isCEI`): the callback runs after `transferFrom` and before `_mint`; a `withdraw` from the hook reverts on the not-yet-credited balance.

## 6. P20 — `Vault.deposit` amount vs received; `Oracle._read`

- Vault half: **B-4**.
- `Oracle._read` (L80-92), `test_P20_oracleRead_shapes` (passes): primary `(0, now)` → secondary; 96-byte and 32-byte returns → ignored → secondary; a 64-byte *revert* → `success == false` → secondary; `updatedAt` in the future or `type(uint256).max` → accepted as fresh; exactly at the staleness edge accepted, one second past → secondary; both stale → 0 → `Tranche.getPrice` reverts `InvalidPrice` (P11 [D]). `ChainlinkAdapter` returns `(0, ts)` for `answer ≤ 0`, so a negative feed falls through to the secondary rather than reverting; an overflow in the decimal scaling is caught by the staticcall and also falls through.
- Same-tx discontinuity: **none** — `test_P20_oracle_sameTxReadsAgree_crossBlockJump` shows two reads in one transaction agree; the primary→secondary switch is a cross-block jump of `|p1 − p2|` (10 % in the test), i.e. an ordinary oracle-source risk, and `lockedValue`, `slash` and `totalCapital` all go through the same `getPrice()` in one transaction. INCONCLUSIVE→REFUTED for an intra-tx value move.

## 7. Composability

- **JIT opt-in around the permissionless `chargePremium`** (`test_JIT_optInAroundChargePremium_oneBlockCapture`): attacker with 1M cUSD opted in against 1M honest staked, `optIn → chargePremium → claim` in the same block captures **0**; after one 12-second block it captures `1145186961697336` of an `8246395931586055263` premium = **0.0139 %** (= `12/43200 × 1/2`, first-order expectation `1145332768275841`). The 12-hour time constant makes one-block JIT worthless; holding a day captures ≈ 86 % × share, which is ordinary staking. Borrower opt-in as a standing strategy is P8 [lead].
- **Same-timestamp early returns** (`_chargePremium` L171, `premiumIndices` L131, `_accrue` L233, `_accrueAverage` L255): all mean "no time elapsed ⇒ nothing accrues", which is correct; a borrow+repay in one block pays nothing because nothing was lent for any time. `updateUnderwriterRate` and `_chargePremium` in the same block agree on the cached index.
- **Flash deposit into cUSD** at par is free and instantly reversible while `badDebt == 0`; its only lever is the utilization EMA (P6 [lead]). `fund()` as a lever is dominated by deposit-and-hold (the funded cUSD vests to stakers, not back to the funder).
- **`_claimFifo` 3-arg path** burns shares before moving assets; a re-entrant read in between would see a higher share price on a tranche (assets constant, supply lower). There is no external call in between (Vault 6909 transfer, no hooks), so it is unobservable.

## 8. State mid-transaction — what is temporarily false, and who can see it

| External call (from) | Invariant temporarily violated while in flight | Observable by |
|---|---|---|
| `Tranche.slash` → `Vault.withdraw` → token hook (`FloatingMarket.liquidate`, `FixedMarket.liquidate`) | `totalDebt()` still the pre-liquidation figure while the liquidator's cUSD is already burned and tranches already slashed: `Σ_m totalDebt_m > creditBackedSupply` (I30) by `repaid`; `healthiness` under-reported; `lockedValue` over-reported | the recipient's hook; anyone it calls. Effect: every exit gate stricter (§5). The Underwriter mark is stale in the same window (P4) |
| `BaseMarket._chargePremium` → `Stablecoin.fundCreditBacked` / `mintCreditBacked` + `Tranche.fund` | between the first mint and the last `fund`, `creditBackedSupply` has risen but `lastLiquidityIndex`… not yet written; `totalDebt()` (from `index()`) already includes the growth | no external hook; cUSD and `Tranche.fund` are hookless and MARKET-gated |
| `Underwriter._transferIn` → `_allocate` → `Tranche.deposit` → `_mark` (inside the underwriter's own `_deposit`) | `debt[tranche]`/`totalDebt` re-marked **before** the depositor's shares are minted at the pre-mark `previewDeposit` quote (I37 momentarily fresh, share count stale) | the depositor's own transaction only; the economic version is P4 [C] |
| `ERC7540AsyncRedeem._claimFifo` → `_consumeRequest` ×n → `_payout` | shares burned, assets not yet transferred: on a Tranche `unlockedSupply()` and `convertToAssets` read higher than the end state | no external call in the window |
| `Stablecoin._payout` → `_onWithdraw` (`badDebt -=`, IRM) → `_transferOut(USDC)` | `badDebt` reduced before the USDC leaves | USDC has no hooks; a hooked underlying would see `backing()` ahead of the reserve by `assets` |
| `Vault.deposit` → token `transferFrom` hook → `_mint` | tokens received, 6909 not credited (I12 in the conservative direction) | the depositor's token hook; `withdraw` reverts (`test_P19_vaultDepositHook_isCEI`) |
| `PremiumVesting.claim` → `safeTransfer(cUSD)` | `pending/debt` zeroed before the transfer | cUSD hookless |
| `Wrapper._deposit/_withdraw` → `Stablecoin.claim` | wrapper's cUSD balance rises before shares are minted/burned — correct direction (claim is folded into `totalAssets` first) | none |

## Invariants

- **I34 broken** (1 wei) — B-3.
- **I35 broken** by GUARDIAN alone — B-2.
- **I12 broken** for fee-on-transfer/rebasing collateral — B-4.
- **I33 held** across 48k handler calls (both queues), including `transferRequest` churn.
- **I26 held** across 48k calls, including the bad-debt regime with a partially removed reserve.
- New invariants the code implies: (a) every queued payout ≤ `unlockedSupply()` at claim time (`_claim` L435) — held; (b) `controllerRequests[c]` growth is only by actions `c` consented to — **not** held (B-1); (c) on the Stablecoin, `balanceOf(this) − redemptionQueue()` is the only balance `claim` may pay from — not enforced (B-3); (d) `badDebt + creditBackedSupply ≤ totalSupply` must be enforced at the guardian entry, not only at the market entry (B-2).

## Hypotheses

- **P2 — CONFIRMED (Medium).** 3-arg `redeem`/`withdraw` exceed 30M gas at n ≈ 290 (2 tranches), 248 (4 tranches), 350 (cUSD); `maxRedeem` at n ≈ 930 (4 tranches). Attacker 172k gas/id (121k direct); victim sheds at 73–96k/id; no bound on `controllerRequests`; protocol actors unaffected (4-arg only).
- **P3 — REFUTED.** Per-request clamp + `_claim` check + `remainingUnlocked` bound every payout by live liquidity; 48k handler calls, no over-claim, no health flip, I26/I33 intact.
- **P19 — REFUTED.** Only hook point is `Vault.withdraw` in `slash`; the write-debt-last ordering leaves every unhealthy market's tranches fully locked for the recipient, the market guard holds, junior deposits price on the post-slash base; read-only reentrancy is pessimistic. The stale-mark underwriter exit it can perform is P4 [C].
- **P20 — half CONFIRMED (Low, B-4) / half REFUTED.** `Vault.deposit` mints nominal; `Oracle._read` handles every shape tested and has no intra-tx discontinuity.

## Appendix: gas & style

- `ERC7540AsyncRedeem.redeem/withdraw` 4-arg accept `_shares = 0` / `_assets = 0` on *any* id (even a stranger's or a consumed one): `_consumeRequest(msg.sender, 0, id)` is a no-op but `_burn(this, 0)`, `_onWithdraw` (an `IRM.updateLiquidityRate()` on the Stablecoin) and a `Withdraw(…, 0, 0)` event still run. Harmless; reject `_shares == 0`.
- `requestRedeem` with `_controller == address(this)` or `DeadShares.HOLDER`, and `transferRequest(id, address(this))`, strand the escrowed shares permanently (the vault can never be `msg.sender` of a claim). Self-harm; the stranded shares stay slashable and never earn. Reject those controllers.
- `_claimableShares` calls `unlockedSupply()` before checking the window; hoisting it (B-1 fix 1) also saves the oracle walk on every `pendingRedeemRequest` view.
- `_claimFifo` copies the whole `EnumerableSet` to memory and sorts on every claim; the set is append-mostly with monotonic ids, so a sorted insert at `requestRedeem`/`transferRequest` time would make claims O(k) in the ids actually consumed.
- `Stablecoin.fund(0)` and `coverBadDebt(0)` (when `badDebt > 0`) succeed and emit; both are free `updateLiquidityRate` pokes.
- `PremiumVesting.claim` NatSpec ("the ordinary case under-pays") is true per account but not for the sum — B-3 is the concrete case.
- `LiquidationReentrancy.t.sol` covers `repay`/`liquidate` re-entry and the kill latch; it does not cover the senior-exit, junior-deposit or underwriter-exit attempts in §5 — worth lifting `B_P19_Reentrancy.t.sol` into the suite.
