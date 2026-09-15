# WS-C — Coverage accounting, tranches, Underwriter curator vault, slash waterfall, premium distribution

Files read end to end: `contracts/cap/Tranche.sol`, `contracts/cap/Underwriter.sol`,
`contracts/cap/market/BaseMarket.sol`, `contracts/utils/PremiumVesting.sol`,
`contracts/ERC7540/ERC7540AsyncRedeem.sol` (+ `ERC7575.sol`, `ERC7540Operator.sol`, `ERC1155Queue.sol`),
`contracts/interfaces/{ITranche,IUnderwriter,IBaseMarket}.sol`, plus the callers that matter for
the hypotheses: `FloatingMarket.sol`, `FixedMarket.sol` (borrow / `_chargePremiumForTerm`),
`Vault.sol`, `Registry.sol` (role wiring), `DeadShares.sol`, OZ 5.7.0 `ERC4626Upgradeable`
(`_transferIn/_transferOut` hooks, `deposit/redeem` ordering).

PoCs live in `audit/tests/scratch/C/`. Run with
`FOUNDRY_TEST=audit/tests/scratch/C forge test --match-path 'audit/tests/scratch/C/*' -vv`
(scoped to `C/` because `audit/tests/scratch/LEAD/OracleDecimals.t.sol` imports a path that does
not exist and breaks compilation of the whole `audit/tests` root; not mine to fix). Every
Medium+ finding below names a test that **fails on current code**; output is pasted verbatim.

Summary: **1 High, 2 Medium, 4 Low, 6 Informational.** I14 fuzz (3,000 runs) found no
conservation violation in `PremiumVesting`.

---

### [HIGH] Underwriter depositors redeem at a stale mark after a tranche slash, extracting the loss from those who stay
**Location:** `contracts/cap/Underwriter.sol:345-347` (`totalAssets`), `:193-209` (`_mark`), `:377-379` (`unlockedSupply`); the inherited, ungated `redeem`/`withdraw`/`requestRedeem`/`redeem(requestId)` in OZ `ERC4626Upgradeable` and `ERC7540AsyncRedeem.sol:77-120`
**Impact:** `Underwriter.totalAssets() = idle vault balance + totalDebt`, and `totalDebt` is a
cached valuation refreshed only inside `allocate`, `deallocate`, `deallocateAsync`,
`finalizeDeallocateAsync` and `report` (KEEPER). Every share-price consumer — `previewRedeem`,
`previewWithdraw`, `maxRedeem`, `unlockedSupply`, `claimableRedeemRequest`, `previewDeposit` —
reads the cache. After a tranche is slashed, any depositor can redeem (instant path or queued
path) at the **pre-slash** price, paid from the idle balance, until a KEEPER calls `report`.
There is **no permissionless way to refresh the mark**. The exiting depositor with share fraction
`f` extracts `f × L` of the unrecognised loss `L` from the remaining depositors, bounded by the
idle balance. In the PoC (two equal depositors, 50 % allocated, one liquidation slashing 170 of
500 tokens) the exiting depositor is paid 500 tokens against a fair 415 and the remaining
depositor's position drops from a fair 415 to 330 — **85 tokens (20 % of his fair share)
transferred, silently, with the vault reporting itself healthy the whole time.** The same
stale price also mis-prices deposits in the window (a new depositor overpays), and the
`IUnderwriter.debt` NatSpec itself admits the number is "an upper bound".
**Likelihood:** Preconditions: (1) an idle balance in the Underwriter — true whenever the curator
keeps a liquidity buffer, has no `defaultTranche`, runs more than one tranche and rebalances
(`deallocate` from T2 marks only T2, leaving T1 stale), or has settled an async deallocation;
(2) a slash on an allocated tranche; (3) the window until the next `report`. Liquidations are
public on-chain events (`Liquidate`/`Slashed`), so a depositor can bundle a redeem in the same
block. Attacker: any admitted Underwriter depositor (deposit is allow-listed; redeem is not), or
the curator themselves, who can manufacture idle by deallocating an unslashed tranche. Cost: gas.
**Exploit path:**
1. Underwriter holds 1000 (A: 500, B: 500); curator allocates 500 to tranche T, keeps 500 idle.
   `debt[T] ≈ 500`, `totalAssets = 1000`.
2. Market borrows 250 against T (health 1.6). Collateral falls 40 %; LIQUIDATOR repays 100 cUSD
   and slashes 102 USD = 170 tokens from T. T now holds 330. Underwriter's true assets: 830.
   `totalAssets()` still reports 1000.
3. A calls `underwriter.redeem(500 shares)`: `maxRedeem = min(500, previewWithdraw(500 idle))`
   at the stale price = 500 shares. A receives 500 tokens (fair: 415).
4. KEEPER calls `report(T)`: `totalDebt` falls to 330; `totalAssets = 0 + 330`, supply ≈ 500.
   B's 500 shares are now worth 330 (fair: 415). Net: A +85, B −85.
   The queued path (`requestRedeem` → `redeem(requestId)`) pays out identically because
   `redeem(requestId)` prices with `previewRedeem` at claim time.
**Proof:** `audit/tests/scratch/C/C1_StaleMark.t.sol` — both tests fail:
```
[FAIL: exiting depositor must not be paid above the true share price: 499999999999999998500 > 414999999999999998841] test_H2_exitAtStaleMarkAfterSlash()
Logs:
  tranche assets after slash (tokens): 330000000000000000000
  underwriter true assets: 829999999999999999340
  underwriter reported totalAssets (stale): 999999999999999999000
  alice fair share: 414999999999999998840
  alice actually paid: 499999999999999998500
  bob value after report: 330000000000000000180
  bob loss transferred from alice: 84999999999999998660
[FAIL: queued claim paid at stale mark: 499999999999999998500 > 414999999999999998841] test_H2_queuedExitAlsoAtStaleMark()
```
**Recommendation:** Price every entry and exit off a live mark. Override `deposit`, `mint`,
`withdraw`, `redeem` (both overloads) in `Underwriter` to iterate `_registeredTranches` **plus any
tranche with `debt[t] > 0`** and call `_mark(t)` *before* the preview is taken (the OZ `redeem`
computes `previewRedeem` before `_withdraw`, so an `_onWithdraw` hook is too late). Also expose a
permissionless `mark(address tranche)` so depositors are not hostage to the KEEPER. Second-order:
`_mark` reads `previewRedeem`, which needs no oracle, so the loop cannot be bricked by a stale
feed; gas grows linearly with tranche count, which the curator controls. Keep `report` for the
premium sweep only.
**Invariant broken:** I16 (redeem/deposit against a stale Underwriter mark). Suggested new
invariant: `Underwriter.totalDebt == Σ_t previewRedeem(balanceOf(t)+queuedShares[t])` at the
start of every deposit and withdrawal.

---

### [MEDIUM] One stale oracle feed on any tranche bricks liquidation, write-off, borrowing and every tranche's redemption for the whole market
**Location:** `contracts/cap/Tranche.sol:328-331` (`getPrice`), `:271-278` (`unlockedSupply`), `:281-288`; `contracts/cap/market/BaseMarket.sol:270-292` (`lockedValue`, `totalCapital`), `:217-221`, `:245-267`, `:350-353`, `:404`
**Impact:** Every market-level coverage figure is `Σ_tranches Tranche.totalCapital()`, and each
term divides by that tranche's own oracle price, which reverts when stale or zero. So a single
dead feed on *any* tranche — including a junior tranche holding 0.1 % of the capital — makes
`healthiness()`, `maxLiquidatable()`, `recoverableDebt()`, `unrecoverableDebt()`,
`availableCredit()`, `liquidate()`, `writeOff()` and `setTranches()`' health check revert. The
senior tranche's `unlockedSupply()` walks the junior tranches through `lockedValue`, so senior
holders cannot redeem either (`maxRedeem` reverts). Only `repay` survives: the borrower can leave,
the underwriters cannot, and the collateral that *is* priced cannot be liquidated while it falls.
This is a depositor-protection failure: the protocol's promise that unhealthy debt is liquidated
against collateral fails on an input that has nothing to do with the collateral in question.
**Likelihood:** No attacker capital; the precondition is a feed outage (primary and backup) on
one tranche's asset while another tranche's collateral moves. Multi-asset markets are a
first-class feature (`Registry.createMarket(assets[], …)`, `_deployTranche` prices each asset).
Long-tail collateral with thinner feeds is exactly what a junior tranche is for. Escape hatch:
ADMIN can `setTranches` without the affected tranche — but that removes its capital from the
waterfall and, because the removed tranche's `market` still points here, its holders then read
`lockedValue == 0` and exit freely once their feed returns.
**Exploit path (liveness, not profit):**
1. Market: senior tranche 1000 of asset A, junior tranche 1 of asset B. Borrow 400.
2. B's feed goes stale (`Oracle.price` reverts). A falls 70 % → true health 0.6.
3. `liquidate` reverts with `PriceError(B)`; so does `writeOff`. Debt keeps accruing premium
   (minting unbacked cUSD, see H1/H3) against collateral nobody can seize.
**Proof:** `audit/tests/scratch/C/C3_OracleBricksLiquidation.t.sol`:
```
[FAIL: PriceError(0x3Cff5E7eBecb676c3Cb602D0ef2d46710b88854E)] test_oneStaleFeedBricksLiquidationAndRedemption()
Logs:
  market.healthiness: REVERT
  market.maxLiquidatable: REVERT
  market.unrecoverableDebt: REVERT
  market.availableCredit: REVERT
  market.writeOff (GUARDIAN): REVERT
  senior.totalCapital (own feed fine): ok
  senior.unlockedSupply: REVERT
  senior.maxRedeem(alice): REVERT
  junior.unlockedSupply: REVERT
  market.repay: ok
```
**Recommendation:** Make coverage arithmetic fail *safe* rather than *closed*: in `totalCapital`
/ `lockedValue`, treat a tranche whose price is unavailable as **zero capital** (conservative for
health, liquidation and borrowing), via a `try ITranche(t).totalCapital()` or a non-reverting
`Tranche.capitalOrZero()`; keep the revert in `slash` itself (a slash at an unknown price must not
happen) but let `_liquidate` skip an unpriceable tranche and continue up the waterfall.
Second-order: zeroing a large tranche's capital on a transient outage would make a healthy market
look liquidatable — pair the zero-valuation with a per-tranche grace window in `Oracle`, or gate
`liquidate` on the *slashed* tranche's feed being live (it is) rather than on every feed.
**Invariant broken:** I5 cannot even be evaluated (`healthiness()` reverts); the intended
"liquidatable when unhealthy" property fails.

---

### [MEDIUM] Premium is attributed to whoever holds shares when it arrives, not to whoever carried the exposure — JIT depositors capture accrued and up-front premium
**Location:** `contracts/utils/PremiumVesting.sol:114-116` (`fund` restarts the epoch to *current* holders), `contracts/cap/Tranche.sol:118-124` (`notifyPremium`), `contracts/cap/Underwriter.sol:229-240` (`report`), `contracts/cap/market/FixedMarket.sol:296-318` (`_chargePremiumForTerm` charges the whole term at borrow)
**Impact:** The per-share accumulator only starts crediting a lump when it is *funded*, and it
credits whoever is staked from that moment over the next 6 hours. Two concrete windows:
(a) **Underwriter `report`** (KEEPER cadence) sweeps everything the tranche accrued since the
last report and vests it to the Underwriter's current holders. A depositor who arrives one block
before `report` collects their pro-rata share of the entire inter-report accrual after 6 h.
(b) **FixedMarket charges the whole term's premium up front**, so a tranche depositor present at
borrow + 6 h collects their share of a 30-day premium, then instant-redeems everything the
buffer leaves unlocked (`unlockedSupply` = supply − debt/(lt−buffer)) and leaves the term's risk
to whoever stays. In the PoC the JIT depositor doubles the tranche, takes **50 % of a 30-day
premium (4.11 cUSD on 8.22) for 6 hours of exposure, and redeems 100 % of her collateral**,
leaving the original underwriter alone for the remaining 714 hours.
**Likelihood:** Attacker is an admitted depositor (tranche or Underwriter). Cost: capital parked
6 h plus slash exposure during those 6 h. Signals are public: pending `borrow` calls on a fixed
market, and a keeper's `report` cadence. Profit scales with position size and with how long
premium was allowed to sit before `report`/`notifyPremium`.
**Exploit path (b):**
1. Alice underwrites tranche T with 1000. Carol watches for a fixed-market `borrow`.
2. Carol deposits 1000 into T immediately before `borrow(500, 30 days)`. Premium 8.22 cUSD is
   minted to T and `notifyPremium` funds a 6 h epoch over 2000 staked shares.
3. After 6 h Carol claims 4.11 cUSD, then `redeem(1000)` — `instantUnlockedSupply` is 1274, so
   her whole position is unlocked. Net: +4.11 cUSD for 6 h of a 30-day risk; Alice keeps 100 %
   of the remaining 29.75 days' risk for half the pay.
**Proof:** `audit/tests/scratch/C/C2_JitPremium.t.sol`:
```
[FAIL: carol collected half a 30-day premium for 6 hours of exposure, then left: 4109589041095890412 != 0] test_JIT_fixedMarketUpfrontPremium()
Logs:
  30-day term premium minted to tranche at borrow (cUSD): 8219178082191780821
  carol claimed after 6h: 4109589041095890412
  carol shares: 1000000000000000000000
  tranche instantUnlockedSupply: 1273972602739726027399
  carol redeemed collateral: 1000000000000000000000
  hours of term remaining, carried by alice alone: 714
[FAIL: a depositor absent during accrual should earn nothing from it: 3314841198817717851 != 0] test_JIT_underwriterReportWindow()
Logs:
  premium accrued to underwriter over 30d (cUSD): 6629682397635435696
  carol (0 days exposure) claimed: 3314841198817717851
  alice (30 days exposure) claimed: 3314841198817717844
```
**Recommendation:** Vest over the *risk* period, not a fixed 6 h: for fixed loans, `notifyPremium`
should take a period argument equal to the term (or the market should stream the term premium via
the floating-style index rather than minting it at once). For the Underwriter, `report` should be
callable by anyone (removes the cadence signal) and the tranche should expose the accrued-but-
unclaimed premium so `_mark`/`totalAssets` can carry it — then a JIT deposit pays for it in the
share price. At minimum, checkpoint a deposit's *entry time* and pro-rate the first epoch.
Second-order: a longer vesting period widens the window in which queued shares (Low finding
below) forfeit yield.
**Invariant broken:** None listed. New invariant the code implies but does not enforce: premium
credited to an account is proportional to `∫ balance · dt` over the accrual period.

---

### [LOW] Queued shares stop earning but stay fully slashable; in a single-tranche market the sole underwriter's premium is redirected wholesale to cUSD stakers while their capital is locked
**Location:** `contracts/cap/Tranche.sol:264-268` (`stakedSupply` excludes the queue), `:337-339`; `contracts/cap/market/BaseMarket.sol:455-459, 471-479` (`_chargePremium` skips `stakedSupply()==0`, remainder → senior or `stakedStablecoin`)
**Impact:** Requesting a redemption is the only way to reserve a place in the FIFO exit. Doing so
moves the shares out of `stakedSupply` (no premium) but not out of `totalSupply`/`totalAssets`
(still locked by `lockedValue`, still slashed). An underwriter who queues while debt is
outstanding bears 100 % of the risk for 0 % of the pay until the *borrower* chooses to repay; the
forfeited premium goes to the senior tranche, or to stcUSD holders when no senior is staked. This
is H12 in its exact form: with one tranche, all 30-day underwriter premium (≈ 6.6 cUSD on 500
debt) lands on `stakedStablecoin`, and the queued position is then slashed from 714 to 612.
**Likelihood:** No attacker; it is a documented design choice ("shares queued for redemption stop
earning"). Reported because the consequence — the only exit mechanism is a total yield forfeit
with unchanged risk — is an incentive not to queue, which makes an orderly wind-down less likely,
and because H12 asked for the enumeration. States in which underwriter premium is redirected:
(1) any junior tranche with `stakedSupply()==0` → its weight to senior; (2) senior with
`stakedSupply()==0` → its weight (plus all skipped juniors' and rounding dust) to `stakedStablecoin`;
(3) all tranches unstaked → 100 % to `stakedStablecoin`. "Unstaked" includes fully-queued
tranches with capital still at risk and wiped tranches with dust supply (see next finding).
**Exploit path:** n/a (no counterparty gains by their own action).
**Proof:** `audit/tests/scratch/C/C5_QueueForfeitsPremium.t.sol` fails:
```
[FAIL: capital that is locked and slashable must be paid for underwriting: 0 <= 0]
Logs:
  shares alice could exit: 285714285714285714286
  shares still queued and locked by debt: 714285714285714284714
  30d underwriter premium routed to tranche: 0
  30d premium (liquidity + redirected underwriter) routed to stcUSD: 8287102997044294622
  alice queued position value after slash: 612285714285714284858
```
**Recommendation:** Pay premium on exposure: divide by `activeSupply() − dead` *plus* queued
shares, tracking the queued entitlement per request id (the ERC-1155 receipt is the natural key),
or pay queued shares at a reduced weight. If the forfeit is kept as a deliberate run-deterrent,
state it in `IERC7540AsyncRedeem.requestRedeem` NatSpec and in the front-end.
**Invariant broken:** none (I14 holds: the premium is conserved, just routed elsewhere).

---

### [LOW] The kill latch retires any *previously used* junior tranche on the first routine liquidation
**Location:** `contracts/cap/Tranche.sol:104-107` (`slash` latch), `:225-241` (`maxDeposit/maxMint` return 0 forever)
**Impact:** The comment claims "an empty tranche sits at par by this test … so an idle slash cannot
brick a tranche before anyone has deposited". True only for a never-used tranche
(`0 > 0·100` is false). A tranche whose holders have all exited still holds the 1e3 dead shares
over ~1e3 wei of dust. It is junior, so every liquidation sweeps it to zero first, and
`1000 > 0` latches `killed`. From then on `deposit`/`mint` revert with `ERC4626ExceededMaxDeposit`
permanently; if it was an Underwriter's `defaultTranche`, every Underwriter deposit reverts until
the curator repoints. Recovery needs ADMIN (`Registry.createTranche` + reweight).
**Likelihood:** Any liquidation in a market whose junior tranche has been used and emptied — an
ordinary lifecycle. No attacker needed; a griefer would need to make the market liquidatable, which
is not cheap. Operational, not fund-loss.
**Proof:** `audit/tests/scratch/C/C4_KillLatch.t.sol::test_H14_exitedJuniorTrancheIsKilledByAnyLiquidation` fails:
```
Logs:
  junior supply after exit (dead shares): 1000
  junior assets after exit (wei): 1000
  junior killed: true
  re-deposit into junior: REVERT (ExceededMaxDeposit)
```
**Recommendation:** Compare against `stakedSupply()` rather than `totalSupply()`
(`stakedSupply() > totalAssets() * KILL_RATIO`), which reads zero for a tranche with only dead
shares, and/or require `totalAssets()` to have been non-trivial before the slash. H14's other
angle — forcing the latch cheaply from outside — could **not** be demonstrated: mints are always at
the live ratio (`previewDeposit` ignores `totalAssets` only when `totalSupply == 0`, and the dead
shares make that a one-shot at par), so only a >99 % slash moves the ratio, which is the intended
trigger.

---

### [LOW] A wiped tranche keeps its full premium weight; weights are static and never capital-scaled
**Location:** `contracts/cap/market/BaseMarket.sol:455, 460` (`_chargePremium` gates on `stakedSupply`, pays by fixed `weight`)
**Impact:** After a slash that takes 100 % of a junior tranche, its holders own shares over zero
assets, bear no further risk, yet continue to receive `weight × underwriterPremium` — 5 % of all
underwriter premium in the default configuration — until the market owner notices and reweights.
More generally a tranche with 1 wei of capital and a 50 % weight earns 50 % of premium; the
`stakedSupply()==0` test is the only capital-awareness.
**Likelihood:** Follows automatically from any liquidation that wipes a junior tranche. Loss to
the tranches that are still underwriting is the wiped tranche's weight × premium per period.
**Proof:** `audit/tests/scratch/C/C4_KillLatch.t.sol::test_wipedTrancheKeepsEarningItsWeight`:
```
[FAIL: a tranche with zero capital bears no risk and should earn no premium: 314909913887683196 != 0]
Logs:
  premium minted to wiped junior over 30 days (cUSD): 314909913887683196
  premium minted to senior over 30 days (cUSD): 5983288363865980717
```
**Recommendation:** Skip tranches with `totalAssets() == 0` (or below a dust floor) in
`_chargePremium`, or weight by `weight × totalCapital` normalised across tranches.

---

### [LOW] Public `FloatingMarket.chargePremium()` restarts the tranche vesting epoch on every call, turning the advertised linear 6 h release into exponential decay
**Location:** `contracts/utils/PremiumVesting.sol:114-116` (`fund` → `_restart(locked()+amount, period)`), `contracts/cap/Tranche.sol:118-124`, `contracts/cap/market/FloatingMarket.sol:106-108`
**Impact:** `Registry._configureTrancheRoles` restricts `notifyPremium` to the market precisely
so "nobody can restart the release schedule by donating a wei of premium and poking it … turning
linear release into decay that never finishes". But `chargePremium()` is public and any call with
≥1 wei of new accrual triggers `notifyPremium` → `fund` → full restart. Every borrow and repay
does the same. With a poke every 10 minutes, **36 % of a lump is still locked after one full
nominal period** (e⁻¹), and holders' claimable lags what `vestingPeriod()` promises. Combined with
the JIT finding above, an actor can keep a lump partially locked until their own capital is in
place. Nothing is lost (asymptotic release), so Low.
**Likelihood:** Free (gas only); already happens organically on active markets.
**Proof:** `audit/tests/scratch/C/C8_EpochRestart.t.sol`:
```
[FAIL: vesting is advertised as linear over the period: 4246234966863291213 < 6629682397635435696]
Logs:
  lump funded at t0 (cUSD): 6629682397635435697
  claimable after 6h, unpoked: 6629682397635435696
  claimable after 6h, poked every 10 min: 4245234966863291213
  still locked, poked (bps of lump): 3596
```
**Recommendation:** In `fund`, keep the existing epoch's end for the carried `locked()` amount and
open a parallel/merged schedule for the new amount (weighted end time), or only restart when the
new amount exceeds a fraction of `locked()`. Document that the schedule is an EMA-style smoother,
not a linear vest, if the behaviour is kept.

---

## Informational

**I-1 — H5: health may degrade from the ltv line to the buffer edge through withdrawals alone (by design, quantified).**
`variableCreditLimit = ltv × activeCapital`, `lockedValue = totalDebt/(lt−buffer)`. With defaults
(ltv 0.5, lt 0.8, buffer 0.1) a borrow lands at health 1.6; redemptions are then allowed down to
health `lt/(lt−buffer) = 1.1429`, a state the borrow gate would never have permitted, and
`creditLimit` (250) falls below `totalDebt` (500) with no borrower action. A further 12.5 % price
move liquidates. The early-queuer does **not** escape the slash: queued shares stay in
`totalSupply`/`totalAssets` and are slashed pro-rata; FIFO only orders who gets the buffer. Could
not demonstrate an exit "ahead of the slash" beyond what the buffer explicitly permits.
`C7_BufferAndDecimals.t.sol::test_H5_*` logs: health 1.6 → 1.142857, creditLimit 250 < debt 500.
The safety of this depends on I8 (`ltv + buffer ≤ lt`) being enforced everywhere — WS-E/H8 note
that Registry defaults bypass the setters' checks.

**I-2 — Slash waterfall arithmetic (reviewed, no defect).** `slash` caps at `totalAssets` and
returns `total·price/unit ≤ value`, so `toSlash -= slashedAmount` cannot underflow; the loop
under-slashes by at most one asset unit per tranche (floor in `value·unit/price`), never over.
`repaid ≤ maxLiquidatable ≤ recoverableDebt = totalCapital/(1+bonus)` bounds `toSlash` by total
capital. Verified with a 6-decimal collateral: `slashedValue − delivered < 1 unit`
(`C7::test_sixDecimalCollateralPaths`, passes). `recipient` is caller-supplied but the caller is
LIQUIDATOR-only. The `Liquidate` event's `assetsSlashed` is a USD value, not an asset amount
(naming). A junior tranche with `totalAssets()==0` still receives a `Vault.withdraw(asset, 0, …)`
→ `safeTransfer(0)`; a collateral that reverts on zero-value transfers would brick liquidation of
that market — listing-policy note for `IVault`.

**I-3 — `lockedValue`/`unlockedSupply` revert paths.** None found: `previewWithdraw` ceil never
reverts; `lockedAssets > totalAssets` yields `unlocked = 0`; 6-decimal path checked
(`unlockedSupply == 1000e6 − 571428571`). A tranche removed from the market's list (`setTranches`)
but still pointing at the market computes `lockedValue` with no `break`, subtracting every
tranche's capital → typically 0 → fully unlocked; intended when retiring, worth a comment.

**I-4 — Shares transferred directly to the Tranche/Underwriter contract are stranded and inflate `stakedSupply`.**
`_update` skips checkpointing when `to == address(this)`, and such shares are not in
`redemptionQueue`, so they count as staked, earn premium nobody can claim (stranded in the
tranche's cUSD balance forever, diluting real holders), and can never be burned (queued burns are
bounded by ERC-1155 receipts). Self-inflicted, but it breaks I13 ("shares held by the vault ==
`redemptionQueue()`") by a plain ERC-20 transfer. Recommend reverting in `_update` when
`to == address(this)` unless called from `requestRedeem`.

**I-5 — `notifyPremium` donation attribution (reviewed, no defect).** A cUSD donation before
`notifyPremium` is picked up at the next notify and vested to current holders — a gift, not an
attack; `claim`'s clamp to `_storedPremiumBalance` and the `balanceOf − stored` diff stay
consistent across claims. Donations cannot restart the epoch themselves (MARKET-only), but see
the Low finding on public `chargePremium()`.

**I-6 — Underwriter miscellany (reviewed).** `addTranche` grants ERC-6909 operator rights over the
Underwriter's entire balance (all ids) to an *unchecked* address; ADMIN-only and documented in
`Registry`. `removeTranche` while allocated does not trap funds: `deallocate(t, 0)` and the async
path still work and re-mark (though `report(t)` reverts with `NotRegisteredTranche`, so premium
for a removed-but-allocated tranche can no longer be swept — recommend allowing `report` on any
tranche with `debt[t] > 0`). `deallocate` short-fills silently but returns the fill; `_mark` is
unconditional so the cache is right either way. `finalizeDeallocateAsync` correctly refuses
receipts it did not create. The `_mark` derivation from the remaining position is sound and
cannot go negative.

**I14 fuzz (`C6_VestingFuzz.t.sol`, 3,000 runs × 8–40 ops of accrue/fund/setPeriod/checkpoint/settle/warp):**
no run where `settled + Σ claimable > funded + 1 wei/op`, no run where another account's action
lowered an entitlement, `lastUpdate ≤ end()` always. The "slide while supply is zero" logic
(`PremiumVesting.sol:98-104`) behaved as documented under the fuzz. Passes; not a finding.

---

## Invariants

**Broken (with evidence):**
- **I16** — `Underwriter.redeem/withdraw/deposit/mint` and both queued-claim paths act on a stale
  mark (High finding). Every other I16 path checked in these files (tranche slash, premium charge)
  accrues first.
- **I5** — cannot be evaluated when any tranche feed is stale; `healthiness()` reverts and
  liquidation is impossible while the market is unhealthy (Medium finding).
- **I13** — breakable by a direct ERC-20 transfer of shares to the vault contract (I-4).

**Held under test:** I14 (3,000-run fuzz), I7 (`lockedValue` is monotonic by construction: senior
locks `max(0, junior-locked − junior-capital)`), I9 within this scope (`previewRedeem` only falls
through `slash`; premium never touches the share price).

**New invariants the code implies but the plan does not list:**
- `Underwriter.totalDebt == Σ_t ITranche(t).previewRedeem(balanceOf(t) + queuedShares[t])` at the
  moment any share is minted or burned (would have caught the High).
- `∀ market: if ∃ tranche with a live feed and `totalDebt > lt × Σ_live capital`, then
  `liquidate` must not revert` (fail-safe, not fail-closed, coverage arithmetic).
- A tranche with `totalAssets() == 0` receives no premium (`_chargePremium` capital-awareness).
- Premium credited to an account over `[t0, t1]` is proportional to `∫ balance dt` on the tranche
  it underwrote (attribution by exposure).
- `killed` may only latch on a tranche whose `stakedSupply() > 0` at the time of the slash.

## Appendix: gas & style
- `BaseMarket.lockedValue` and `totalCapital` each re-read every tranche's oracle; `_liquidate`
  calls `healthiness()` (N reads) then `maxLiquidatable()` (N reads again) then `slash` per tranche.
  Cache `totalCapital` once per call.
- `IBaseMarket.Liquidate.assetsSlashed` is a USD value; rename `valueSlashed`.
- `Tranche.slash` emits `Slashed(recipient, assets, slashedValue)` before the `Killed` check; fine,
  but `Killed` carries no context (tranche is implicit) — consider emitting the post-slash ratio.
- `Underwriter.report` emits `Reported(tranche, premium, gain, loss)` where `gain`/`loss` are
  mutually exclusive; a signed delta would be clearer.
- `PremiumVesting.rate()` is documented as informational only; `IUnderwriter.premiumPerSecond`
  exposes it and will drift from actual accrual, as the NatSpec admits.
