# Workstream B — ERC-7540 async redemption queue, run mechanics, operator/controller auth, first-depositor protection

Scope read end to end: `contracts/ERC7540/{ERC7540AsyncRedeem,ERC7540Operator,ERC7575,ERC1155Queue}.sol`,
`contracts/utils/DeadShares.sol`, the four queue interfaces, `contracts/cap/{Stablecoin,Tranche,Underwriter}.sol`,
`contracts/cap/market/BaseMarket.sol` (`lockedValue`, `totalCapital`, `variableCreditLimit`, `healthiness`),
`contracts/utils/PremiumVesting.sol`, OZ 5.7.0 `ERC4626Upgradeable.sol` and `ERC1155.sol`.

Tests: `audit/tests/scratch/B/` — run with
`FOUNDRY_TEST=audit/tests forge test --match-path 'audit/tests/scratch/B/*' -vv`
(invariant suites: add `FOUNDRY_INVARIANT_RUNS=48 FOUNDRY_INVARIANT_DEPTH=60`; the default 256x500 with the
O(n²) receipt-dedupe in the Stablecoin suite runs >7 min).

| File | Purpose | Result on current code |
|---|---|---|
| `B1_OutOfOrderSettlement.t.sol` | PoC for B-1 (3 tests) | **3 FAIL** |
| `B1b_ControlAndUnderwriter.t.sol` | control (no out-of-order settlement) + Underwriter flavour | control PASS, Underwriter **FAIL** |
| `B_QueueInvariants.t.sol` | handler fuzz: Stablecoin queue (I1, I13, I15, Σclaimable≤unlocked); Tranche queue (I13, Σclaimable≤unlocked) | Stablecoin 4/4 PASS; Tranche I13 PASS, Σclaimable **FAIL** (shrunk to 6 calls) |
| `B_DeadSharesAndMisc.t.sol` | 10 passing demonstrations backing the Info/Low notes and the refuted hypotheses | 10 PASS |

---

### [HIGH] Queue settlement is order-dependent: a later request that settles first permanently over-credits every earlier open request, so claims can exceed `unlockedSupply()` and drain collateral the market reports as locked
**Location:** `contracts/ERC7540/ERC7540AsyncRedeem.sol:123-140` (`claimableRedeemRequest`), `:226-247` (`_withdraw`, queued; `$.settledQueue += _shares` at L241); consumers `contracts/cap/Tranche.sol:271-278` (`unlockedSupply`), `contracts/cap/Underwriter.sol:377-379` (`unlockedSupply`)

**Impact:**
`claimableRedeemRequest` treats `currentIndex = settledQueue + unlockedSupply()` as a cumulative liquidity high-water mark over the positional queue `[queueIndex, queueIndex + balance)`. That is only correct if every settled share sat *below* every open window, i.e. if settlement happened in queue order. The code permits a later request to claim as soon as its own window is under `currentIndex` (which is exactly when the earlier request is *fully* claimable but not yet claimed). Its settled shares are then added to `settledQueue` and from that moment credit the earlier request's window as if they were liquidity at the head of the queue. Formally: Σ claimable = unlockedSupply + |claimed positions ≥ currentIndex|; the second term is zero only while `currentIndex` never falls below a position that was already claimed.

For `Stablecoin`, `unlockedSupply` only falls through claims themselves and through instant redemptions capped at `unlocked − redemptionQueue`, so `currentIndex` never drops below a claimed position and the fuzz suite confirms Σclaimable ≤ unlocked holds (2,880 calls, 0 violations). For `Tranche` and `Underwriter`, `unlockedSupply` falls exogenously — borrow, interest accrual, collateral price move, slash, and the curator's `allocate` — and the over-credit then becomes real:

- **Tranche**: the earlier request is paid out while `unlockedSupply()==0`, i.e. the tranche is drained *below* `lockedValue` (`totalDebt/(lt−buffer)`). The buffer exists precisely so that redemptions cannot move a market from healthy to liquidatable; in the PoC a single queued claim moves `healthiness()` from 1.12 ray to 0.896 ray and `maxLiquidatable()` from 0 to 407e18. Remaining tranche holders are then liquidated with the bonus; at larger sizes (over-credit ≥ ~30% of tranche capital at max borrow) recoverable debt drops below total debt and the residual is written off onto cUSD holders (`recognizeBadDebt`) — the top severity class in `00-plan.md`.
- **Underwriter**: `claimableRedeemRequest` reports the full request as claimable with zero idle assets; the claim then reverts inside `Vault.transfer` (ERC6909 insufficient balance). A misreport and a liveness failure rather than a theft, but ERC-7540 requires the view to be accurate, and any keeper/integration that sizes `finalizeDeallocateAsync` off it will revert.

Dollars at risk: bounded by the amount settled out of order behind the open request, capped at that request's size. In the PoC 200e18 of a 1,000e18 tranche leaves against a lock; a determined actor can pre-credit an arbitrarily large request by cycling one small chunk through the queue (see path B) at gas cost only.

**Likelihood:**
Preconditions: (1) a request R1 is fully claimable and left unclaimed; (2) one or more later requests settle while R1 is open; (3) `unlockedSupply` then tightens. No privileged actor is required and no unusual state: (1) is the ordinary behaviour of the `Underwriter` (`deallocateAsync` is finalized by a keeper "at leisure", NatSpec L182-189) and of any slow claimant; (2) is any other holder exiting; (3) is every borrow, every block of interest accrual, every price drop. A deliberate actor needs nothing but tranche shares and gas.

**Exploit path (A — organic, as tested):**
Starting state: senior-only market, supplier 800e18 + Alice 200e18 collateral at $1, `ltv 0.5 / lt 0.8 / buffer 0.1`.
1. Borrower draws to the limit: debt 500e18. `lockedAssets = 500/0.7 = 714.3e18`, `unlockedSupply ≈ 285.7e18`.
2. Alice `requestRedeem(200e18)` → window `[0,200e18)`, fully claimable. She does not claim.
3. Carol, Dave, Erin each deposit 80e18, request, and claim (each is claimable because `currentIndex ≥ 280/360/440e18`). `settledQueue = 240e18`. Alice's window is now credited for 240e18 regardless of liquidity.
4. Collateral falls 30%. `lockedAssets = 714.3/0.7 = 1,020e18 > totalAssets` → `unlockedSupply() = 0`. `healthiness() = 1.12e27` (healthy, exactly the designed post-redemption floor `lt/(lt−buffer)`).
5. Alice `redeem(idA, 200e18)` succeeds: `claimableRedeemRequest = min(200e18, 240e18 + 0) = 200e18`.
6. `healthiness() = 0.896e27`, `maxLiquidatable() = 407.8e18`. The remaining 800e18 of collateral is slashed with bonus by the liquidator; Alice holds her 200e18 of collateral untouched. Net: Alice exits a slash that the lock said she must share; the loss is transferred to the supplier (and to cUSD holders if the slash is deep enough to be unrecoverable).

**Exploit path (B — deliberate pre-credit, cost ≈ gas):**
1. Alice deposits `a` and requests `a` while `unlockedSupply ≥ a`.
2. Alice cycles a chunk `b` through the queue `⌈a/b⌉` times: deposit `b` → `requestRedeem(b)` → `redeem` (claimable because her own R1 is fully claimable). Each cycle adds `b` to `settledQueue`; her R1 window is permanently credited for `a`. The same `b` is reused, so the only cost is gas and the forgone premium on `a` while queued.
3. Alice now holds a lock-proof exit for `a`: whenever the market tightens (price drop, accrual, max borrow) she claims and leaves the rest of the tranche holding the slash.

**Proof:**
`audit/tests/scratch/B/B1_OutOfOrderSettlement.t.sol` — all three fail on current code:
```
[FAIL: claimable must never exceed unlockedSupply: 99999999999999999000 > 0] test_B1_juniorClaimSucceedsWhileUnlockedSupplyIsZero()
Logs:
  junior.unlockedSupply()          : 0
  junior.claimable(idA, alice)     : 99999999999999999000
  junior.totalAssets() before claim: 100000000000000000000
  market.lockedValue(junior)       : 714285714285714286429
[FAIL: next call did not revert as expected] test_B1_juniorClaimDrainsLockedTranche()
[FAIL: a redemption must never make a healthy market liquidatable: 896000000000000000000000000 < 1000000000000000000000000000] test_B1_seniorExitFlipsHealthyMarketToLiquidatable()
Logs:
  debt: 500000000000000000000
  health before claim (ray): 1120000000000000000000000000
  alice claimable          : 200000000000000000000
  health after claim  (ray): 896000000000000000000000000
  maxLiquidatable          : 407834101382488479263
```
`audit/tests/scratch/B/B1b_ControlAndUnderwriter.t.sol` — the control (identical junior flow, Bob does not claim) **passes**, proving order-dependence; the Underwriter flavour fails:
```
[PASS] test_B1_control_noOutOfOrderSettlement_lockHolds()
[FAIL: claimable must never exceed unlockedSupply: 99999999999999999000 > 0] test_B1_underwriterClaimableMisreportedAfterAllocate()
```
`audit/tests/scratch/B/B_QueueInvariants.t.sol:B_TrancheQueueInvariants` — the handler fuzz (deposit / request / claim / borrow / repay / warp / price) rediscovers it and shrinks to six calls:
```
[FAIL: sum claimable <= unlocked (tranche): 13648702 > 0]
	[Sequence] (original: 120, shrunk: 6)
		deposit(...)  request(...)  request(...)  borrow(...)  claim(...)  price(0)
 invariant_sumClaimable_le_unlocked() 
[PASS] invariant_I13_trancheQueueConservation()
```
Same suite over `Stablecoin` (48 runs x 60 depth, 2,880 calls, 0 reverts): `invariant_I13_queueConservation`, `invariant_I15_fifo`, `invariant_sumClaimable_le_unlocked`, `invariant_I1_reserveCoversUnlocked` all PASS — the defect is confined to vaults whose `unlockedSupply` can fall for reasons other than a claim.

**Recommendation:**
Minimal and safe: cap every queued payout by live liquidity — in `_withdraw` (queued) add `if (_shares > unlockedSupply()) revert ...;` and in `claimableRedeemRequest` return `Math.min(positional, unlockedSupply())`. Each claim burns exactly what it takes, so the sequence of claims is then bounded by real liquidity while positional priority is preserved (an over-credited early request still takes the first liquidity that returns, which is the intended FIFO). Second-order: the Underwriter's `finalizeDeallocateAsync` sized off `claimableRedeemRequest` stops reverting. Alternatively, make settlement strictly in order (a request may claim only while `queueIndex[id] == settledQueue`), which makes `settledQueue + unlockedSupply` exact but lets one slow head block everyone — the positional design already implies that and the cap is the smaller change. Either way, add `Σ claimable ≤ unlockedSupply` as a permanent invariant test over Tranche and Underwriter (the suite in `B_QueueInvariants.t.sol` can be lifted as-is).

**Invariant broken:** I15 (a request is paid liquidity that was never allocated to its position); I5/I8 indirectly (a healthy market is pushed under `lt` by a redemption the buffer was meant to block). Also the implicit invariant `Σ_open claimableRedeemRequest ≤ unlockedSupply()` that the plan does not list — proposed as I17 below.

---

### [LOW] Requests cannot be cancelled: queued Tranche/Underwriter shares stop earning premium yet keep full slash exposure, for as long as the debt that locks them stands
**Location:** `contracts/ERC7540/ERC7540AsyncRedeem.sol` (no cancel path; `CancelRedeem` event and `CancelExceedsPending` error in `IERC7540AsyncRedeem.sol:18,30` are never used); `contracts/cap/Tranche.sol:264-268,337-339` (`stakedSupply` excludes `redemptionQueue`, premium accrues only to `stakedSupply`); `BaseMarket.sol:270-283` (`lockedValue`/`healthiness` count the queued shares' assets via `totalCapital`)
**Impact:** A holder who requests while the tranche is locked (the normal reason to use the async path) is placed in a position that (a) earns nothing — the premium its share of the collateral was underwriting is re-routed by `_chargePremium` to the senior tranche or `stakedStablecoin`; (b) still absorbs every slash pro rata (slash is a share-price drop over all shares including those parked at the vault); (c) cannot be undone. On a floating market the lock persists for as long as the borrower keeps the line drawn, which can be indefinitely. The only exit is to sell the ERC-1155 receipt. Value at risk: forgone premium on the queued slice for the lock's duration, plus any slash during it. Not extractable by a third party; the beneficiaries are the other tranche holders / cUSD stakers.
**Likelihood:** Any ordinary user or the `Underwriter` (`deallocateAsync`) that queues while `unlockedSupply < balance`. No attacker, no cost.
**Exploit path:** n/a (no profit to a third party). The `ghost controller` variant — `requestRedeem(shares, controller=<address nobody controls>, owner)` — strands the shares forever at the queue head; other holders are *not* harmed by it (the ghost's collateral stays in the tranche as coverage and its position in the queue is neutral versus the ghost having exited), so it is a footgun for the requester only. Demonstrated in `B_DeadSharesAndMisc.t.sol:test_ghostController_strandsSharesAtQueueHead_noCancel` (passes).
**Proof:** behaviour is as documented in `Tranche.sol:333-336`; no failing test, hence Low.
**Recommendation:** Either (i) add `cancelRedeemRequest(requestId, shares, receiver, controller)` that returns still-pending shares from `address(this)` to the receiver, decrements `redeemQueue` **only if the request is the tail** (otherwise positions behind it shift) or, simpler, marks the cancelled slice as settled (`settledQueue += shares`, `queueIndex += shares`) and transfers the shares back — this keeps the positional arithmetic consistent; or (ii) keep accruing premium to queued shares while they are locked (they are still underwriting: `healthiness` counts them), i.e. define `stakedSupply = totalSupply − dead` and only stop accrual for the *claimable* part. (ii) is the cleaner economic fix. Note B-1's fix must land first; a cancel that changes `settledQueue` interacts with the same arithmetic.
**Invariant broken:** none listed; incentive inconsistency between what covers (`totalCapital`) and what is paid (`stakedSupply`).

---

### [INFORMATIONAL] ERC-7201 slot constants verified
**Location:** `ERC7540AsyncRedeem.sol:42-44`, `ERC7540Operator.sol:16-18`
Recomputed `keccak256(abi.encode(uint256(keccak256(ns)) − 1)) & ~0xff` with `cast`:

| Namespace string | Computed | In code | Match |
|---|---|---|---|
| `cap.storage.ERC7540AsyncRedeem` | `0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300` | same | yes |
| `cap.storage.ERC7540Operator` | `0x984a447e9a3f276a50a882321c9dcb50ab53cba0333a097400ab36b1a1a27200` | same | yes |

Also computed for cross-reference (WS-F): `cap.storage.Stablecoin` `0xb4d0fed9…4000`, `cap.storage.Tranche` `0x600efd58…0f00`, `cap.storage.Underwriter` `0xace93d61…2c00`, `cap.storage.BaseMarket` `0x3084c044…2700`, `cap.storage.FixedMarket` `0x3aef348c…8d00`, `cap.storage.FloatingMarket` `0xccd94301…a400` — all distinct from each other and from OZ's `openzeppelin.storage.*` slots. `$.slot := slot` via a `uint256` local is functionally identical to assigning a `bytes32` constant. The `vm.load` helpers in `B_QueueInvariants.t.sol` read `redeemQueue`/`settledQueue`/`queueNft` at `BASE+1/+2/+4` and agree with the public views, which is an executable confirmation of both the slot and the struct layout.

### [INFORMATIONAL] H15 — pre-deposit donation is a windfall to the first depositor; second depositor and `totalCapital` are unaffected; zero-share deposits are accepted
**Location:** `Tranche.sol:247-254`, `Underwriter.sol:353-360`, `DeadShares.sol`
Tested in `B_DeadSharesAndMisc.t.sol` (all pass):
- `test_H15_donationIsWindfallToFirstDepositor_secondDepositorUnaffected`: 1,000e18 donated via `Vault.transfer`, first deposit of 1e18 redeems for 1,000.99e18; the second depositor (100e18) redeems 99.9999e18 (dilution 1.8e-16). `market.totalCapital()` equals the real vault balance × price — nothing phantom, so `variableCreditLimit` is not misled; the donation is genuine collateral owned by the shareholders. **Could not demonstrate** a mispricing; H15's trap hypothesis is refuted, the windfall is confirmed and is documented behaviour.
- `test_H15_inflationAttackLosesMoney`: against a live tranche (attacker 1e3 shares + 1e3 dead), the donation needed to zero a 10e18 victim is 2.001e22; attacker out 1.0005e22 vs in 2.001e22 — unprofitable, as `DeadShares` claims. **However the victim still receives 0 shares and loses the full 10e18** because neither OZ `_deposit` nor the overrides reject `shares == 0`. This is a 2,001:1 griefing, only reachable by an admitted depositor, hence Informational; recommend `if (shares == 0) revert` in `previewDeposit`-consuming paths (and for symmetry a zero-assets check in queued `redeem`, which will burn dust shares for 0 assets on a 6-decimal `Stablecoin` underlying whenever `shares < 1e12`).
- `test_deadSharesAreUnredeemable`: the seed at `0xdEaD` cannot be redeemed, requested (no allowance/operator can ever be set from that address) or counted in `stakedSupply`; `claimable(HOLDER)==0`.

### [INFORMATIONAL] Receipt/operator/allowance model — confirmed sound
`B_DeadSharesAndMisc.t.sol`, all pass:
- Receipt split 60/40 across two controllers: each claims exactly its balance, `queueIndex` advances globally, total paid = original request, vault share balance and `redemptionQueue` return to 0, no double claim (`test_receiptTransfer_movesClaimEntirely_noDoubleClaim`). Note the *view* `claimableRedeemRequest` over-reports for split receipts (each holder's window starts at the same `queueIndex`), but state transitions are sequential and safe.
- An ERC-20 allowance (even infinite) cannot claim a queued position: `NotAuthorized` (`test_allowanceCannotClaimQueuedPosition`); the unit suite already covers this. Hypothesis refuted.
- `instantUnlockedSupply` is guarded (`if (totalUnlocked > queue)`); when the queue exceeds liquidity it returns 0, `maxRedeem`/`maxWithdraw` return 0, nothing reverts (`test_instantUnlocked_zeroNotRevert_whenQueueExceedsUnlocked`). Hypothesis refuted. (Dust: OZ `withdraw` may burn `previewWithdraw(previewRedeem(instantUnlocked))` = up to 1 wei-share more than the instant cap — appendix.)
- Claim-time pricing on `Stablecoin`: a queued position has reserved liquidity and a free timing option, but the haircut curve is claim-time for every path, `settledQueue + unlockedSupply` is monotone for `Stablecoin`, and instant redemptions are capped at `unlocked − queue`, so being queued is never worse than holding and never lets anyone extract more than the curve pays. No asymmetry to exploit beyond ordinary run dynamics (WS-G `run_dynamics.py`). Observation for WS-G: for cUSD, *queueing* is costless (cUSD pays no yield) and grants priority, so in a shortfall the rational race is to *queue* early and *claim* late; the haircut only removes the incentive to claim early.

### [INFORMATIONAL] Contract controllers must implement `IERC1155Receiver`
`ERC1155Queue.mint` → OZ `_mint` → `checkOnERC1155Received`; a controller with code but no receiver reverts `requestRedeem` (`test_contractControllerWithoutReceiver_reverts`, tested with the vault and the market as controllers). Documented at `ERC7540AsyncRedeem.sol:22`. `Underwriter` implements both hooks unconditionally (L438-451) so `deallocateAsync` is not affected. Addresses without code (EOAs, and any not-yet-deployed address) accept silently — which is what makes the ghost-controller footgun in B-2 possible.

### [INFORMATIONAL] Interface and metadata gaps
- No getter for the ERC-1155 receipt contract: `queueNft` is private storage with no accessor and is not in any event; integrators must derive it from the `TransferSingle` log in the request transaction or from `computeCreateAddress(vault, 1)`. Add `function queueNft() external view`.
- `supportsInterface` returns `true` for `type(IERC1155Queue).interfaceId` (`ERC7540AsyncRedeem.sol:289`) although the vault implements none of it; `balanceOf(address,uint256)` on the vault reverts (`test_supportsInterface_misreportsIERC1155Queue`). Remove it or forward.
- `claimableRedeemRequest`/`pendingRedeemRequest` "MUST NOT revert" per ERC-7540, but on `Tranche` they call `unlockedSupply()` → `market.lockedValue()` → every junior's `totalCapital()` → `getPrice()`, which reverts on a stale/zero feed for *any junior tranche's asset*. A stale junior feed therefore freezes every senior holder's instant and queued redemptions (`maxRedeem` reverts too). Fail-closed is the stated intent (`Tranche.sol:317-327`); flagged for WS-E as a liveness dependency on every feed in the waterfall, not just the tranche's own.
- Declared but unused: `CancelRedeem`, `CancelExceedsPending`, `RedeemRequestNotFound`, `NoPendingShares`, `NoClaimableShares`, `ZeroAddress` in `IERC7540AsyncRedeem.sol`.
- Direct ERC-20 `transfer` of shares to the vault address strands them, keeps them in `activeSupply`/`stakedSupply` (so their premium share is credited to no one) and breaks the second clause of I13 (`balanceOf(vault) == redemptionQueue`) without touching the queue arithmetic (`test_donatedSharesToVault_countAsStakedButEarnNobody`). Self-harm only; consider rejecting `to == address(this)` in `_update` outside `requestRedeem`.
- In `requestRedeem` the ERC-1155 mint (with its receiver callback) runs before `emit RedeemRequest`; a re-entrant controller emits nested `RedeemRequest`/`Withdraw` events out of order. State is fully settled before the callback, so no accounting effect.

---

## Invariants

**Broken (with proof):**
- **I15** — broken for `Tranche`/`Underwriter` in the sense that liquidity settled at a later position is credited to an earlier one (B-1). Holds for `Stablecoin` (fuzz).
- **I5 / I8 (indirect)** — a queued redemption can move a healthy market below `lt` (B-1 senior PoC), which the buffer was meant to make impossible.
- **I13 second clause** — `balanceOf(vault) == redemptionQueue()` is violable by a direct share transfer to the vault (harmless; Info). First clause (`Σ receipts == redeemQueue − settledQueue`) holds under fuzz including receipt splits.

**Held under fuzz (Stablecoin):** I1, I13, I15, Σclaimable ≤ unlocked — 48x60 (2,880 calls) and 200x80:
```
[PASS] invariant_I13_queueConservation()      (runs: 200, calls: 16000, reverts: 0)
[PASS] invariant_I15_fifo()                   (runs: 200, calls: 16000, reverts: 0)
[PASS] invariant_I1_reserveCoversUnlocked()   (runs: 200, calls: 16000, reverts: 0)
[PASS] invariant_sumClaimable_le_unlocked()   (runs: 200, calls: 16000, reverts: 0)
```
**Held (Tranche):** I13.

**New invariants the code implies and the plan misses:**
- **I17** — `Σ_{open requests} claimableRedeemRequest(id, controller) ≤ unlockedSupply()` for every vault at all times. This is the statement B-1 violates and is the natural executable form of "the queue never pays past the lock".
- **I18** — for every `Tranche` with `unlockedSupply()==0`, no `redeem`/`withdraw` (instant or queued) succeeds. Equivalent to `totalCapital() ≥ lockedValue()` being preserved by every redemption when it held before.
- **I19** — queue potential monotonicity: `settledQueue + unlockedSupply()` never drops below `queueIndex[id] + balance` of any request that has been (partially) claimed. This is the precise precondition under which the positional arithmetic is sound; it holds for `Stablecoin` and fails for `Tranche`/`Underwriter`.
- **I20** — premium/coverage consistency: shares counted in `totalCapital` for `healthiness` should be the same set that accrues premium (B-2 shows queued shares are in the first set and not the second).

## Appendix: gas & style
- `instantUnlockedSupply()` calls `unlockedSupply()` and `redemptionQueue()`; `maxRedeem` then calls `instantUnlockedSupply()` and `maxWithdraw` calls `maxRedeem` — on `Tranche` that is three oracle round-trips per `withdraw` (`lockedValue` loops every junior tranche). Cache in a memory struct.
- OZ `withdraw(assets, receiver, owner)` can burn `previewWithdraw(previewRedeem(instantUnlocked))` shares, i.e. up to 1 wei-share above the instant cap; harmless, but a `shares ≤ maxRedeem` check in the instant `_withdraw` would make the cap exact.
- `ERC7540Operator` is a non-abstract `contract` with no initializer; fine, but `abstract` would make the intent explicit.
- `_checkAllowance` is `internal` non-view (spends allowance) while `_checkController` is `view`; naming them symmetrically hides that one has a side effect.
- `redeem(uint256,uint256,address,address)`/`withdraw(uint256,uint256,address,address)` deviate from the ERC-7540 3-argument signatures (extra `requestId`). Deliberate given the positional design; document it in the interface NatSpec since generic 7540 tooling will not find them.
