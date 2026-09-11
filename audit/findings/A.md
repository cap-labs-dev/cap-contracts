# Workstream A - cUSD reserve, peg, bad-debt haircut curve

Files read end to end: `contracts/cap/Stablecoin.sol`, `contracts/cap/Vault.sol`,
`contracts/interfaces/IStablecoin.sol`, `contracts/interfaces/IVault.sol`,
`contracts/ERC7540/ERC7540AsyncRedeem.sol`, OZ 5.7.0 `ERC4626Upgradeable.sol`,
`contracts/cap/market/BaseMarket.sol` (`_borrow`/`_repay`/`_liquidate`/`_writeOff`/`_chargePremium`),
`contracts/cap/market/FloatingMarket.sol`, `contracts/cap/market/FixedMarket.sol` (debt paths),
`contracts/cap/InterestRateModel.sol` (`updateLiquidityRate`, `_accrueAverage`, `_index`).

Scratch tests: `audit/tests/scratch/A/{Curve.t.sol, CurveHarness.sol, Reserve.t.sol, DriftStats.t.sol, VaultCallback.t.sol}`.
Run with `FOUNDRY_TEST=audit/tests/scratch/A forge test --match-path 'audit/tests/scratch/A/*' -vv`
(scoped to this directory because another workstream's in-progress `audit/tests/invariants/CapHandler.sol`
does not currently compile under the shared `audit/tests` root).

Summary: **0 Critical, 0 High, 0 Medium, 2 Low, 6 Informational.** The reserve identity and the
haircut curve survived every attack I could construct, at the wei level, at 6/8/18 decimals. The
one invariant that broke is I3, in the harmful direction, by single-digit wei, with a real
liveness consequence.

---

## Notation used throughout

All in 18-dp share units unless stated. `S = totalSupply`, `C = creditBackedSupply`, `B = badDebt`,
`A = totalAssets = S - B`, `R = underlying balance x 10^(18-ud)`, `U = unlockedSupply = S - C - B`.

**Reserve identity (derived, then tested):** `R == U` exactly after every operation, except that
each redemption may strand `< 10^(18-ud)` wei in `R` (the decimal floor on the payout, and the
`reduced > badDebt` cap in `_onWithdraw`), in which case `R > U`. It never goes the other way.
Trace: deposit `+S +R`; `mintCreditBacked` `+S +C`; `burnCreditBacked` `-S -C`; `recognizeBadDebt`
`+B -C`; `coverBadDebt` `-S -B`; redeem of `x` shares paying `a`: `-x S`, `-a R`,
`-(x - a) B` -> `U` falls by exactly `a`. `_onWithdraw` derives the retirement from the assets
actually paid, so the identity does not depend on the curve being correct at all.

---

### [LOW] FloatingMarket premium rounding drifts `totalDebt` above `creditBackedSupply`; full repay and full write-off then revert on underflow
**Location:** `contracts/cap/market/FloatingMarket.sol:L195-L233` (`_chargePremium`, `_premium`);
`contracts/cap/Stablecoin.sol:L76-L81` (`burnCreditBacked`), `L109-L121` (`recognizeBadDebt`)
**Impact:** `_premium` mints `scaled*(U0*(L1-L0)) + scaled*(L1*(U1-U0))` as two independently
half-up-rounded `rayMul` chains, while `totalDebt()` reads `scaled.rayMul(L1.rayMul(U1))`. The two
disagree by a wei-level random walk on every accrual, and the difference is preserved exactly by
every repay/liquidate (`_floorReduction` settles what the reading moved). When the walk sits on the
`debt > credit` side and this market's excess is not covered by slack from other markets' credit
(single market, or every other market has repaid), then:
- `repay(type(uint256).max)` reverts (`creditBackedSupply -= cleared` underflows) - the borrower
  can never clear the loan; the last `gap` wei is unrepayable and keeps a live `scaledDebt`;
- `writeOff()` on a fully-uncollateralised remainder reverts for the same reason, so the GUARDIAN
  cannot stop accrual on a dead loan through the designed route;
- with several markets, the excess is silently burned out of *another* market's credit, moving the
  problem to whichever market repays last.
Dollars at risk: dust (single-digit wei). The cost is liveness/operational: the last market
standing cannot be cleared or written off without a workaround.
**Likelihood:** No attacker needed; just time and accruals. In the stats run below the state
`debt > credit` held after 337 of 365 daily accruals (uw 20%), 362/365 at large principal, 30/365 at
underwriter rate 0. Precondition for the revert: no other market with >= `gap` wei of outstanding
credit at the moment of the final repay/write-off. Workaround: any borrower in any other market
draws >= `gap` wei first (or the guardian writes off a partial amount on a fixed market).
**Exploit path:** not an exploit; a self-inflicted revert path:
1. One floating market, borrower draws 400 cUSD, `chargePremium()` daily for a year (or anyone
   pokes it - it is permissionless) -> `totalDebt = credit + 17 wei`.
2. Borrower acquires `totalDebt` cUSD at par and calls `repay(max)` -> revert (underflow).
3. Borrower repays `debt - 1e18` -> succeeds; gap still exactly 17 wei.
4. Collateral crashes; liquidator strips all collateral (gap still 17); `unrecoverableDebt() ==
   totalDebt()`; GUARDIAN `writeOff()` -> revert (underflow).
**Proof:** `audit/tests/scratch/A/Reserve.t.sol::test_driftBricksFullRepayAndWriteOff` (deterministic)
and `::testFuzz_debtNeverExceedsCredit` (fuzz). Both fail on current code:
```
[FAIL: I3 (repo test assertion): 999999990196078433 > 999999990196078416] test_driftBricksFullRepayAndWriteOff() (gas: 31333162)
Logs:
  totalDebt          : 523762562549696708008
  creditBackedSupply : 523762562549696707991
  gap (wei)          : 17
  capital left (wei) : 2
  remaining debt     : 999999990196078433
```
(the `vm.expectRevert()` on `repay(max)` twice and on `writeOff()` all passed before the final
assertion, i.e. the reverts are real; the test is written to fail on the I3 assertion.)
```
[FAIL: I3: totalDebt > creditBackedSupply: 2079533381551088925248 > 2079533381551088925247;
 counterexample: args=[317058, 0, 1003425878465946108792506139700038988868499483312885463155666460685838546]]
 testFuzz_debtNeverExceedsCredit(uint256,uint8,uint256) (runs: 4, ...)
```
(60 random-interval accruals; the fuzzer finds it on run 4.) Direction/size characterised in
`DriftStats.t.sol::test_driftStats`:
```
daily x365, uw 20%, principal 400       final DEBT - credit : 8   worst : 10  accruals w/ debt>cr : 337
hourly x720, uw 20%, principal 400      final credit - debt : 2   worst : 4   accruals w/ debt>cr : 266
12s x2000, uw 20%, principal 400        final credit - debt : 27  worst : 9   accruals w/ debt>cr : 484
daily x365, uw 0%, principal 400        final DEBT - credit : 1   worst : 2   accruals w/ debt>cr : 30
daily x365, uw 20%, principal 49999     final DEBT - credit : 13  worst : 15  accruals w/ debt>cr : 362
daily x365, uw 20%, principal 1         final credit - debt : 1   worst : 2   accruals w/ debt>cr : 49
daily x1095, uw 20%, principal 400      final credit - debt : 4   worst : 10  accruals w/ debt>cr : 470
```
The existing repo test `test/integration/AccountingIntegrity.t.sol::test_debtNeverExceedsCreditBackedSupply`
asserts `debt <= credit` but only over 20 x 13 s accruals, which is not enough for the walk to
cross; it passes by luck and pins the wrong claim. `FixedMarket` does not have this problem
(`_totalDebt` is incremented by exactly the minted premium; `testFuzz_fixedDebtNeverExceedsCredit`
holds `debt == credit` exactly).
**Recommendation:** Derive the minted premium from the debt reading's own movement, exactly as
`_floorReduction` already does for repayment: in `_chargePremium`, compute
`total = scaledDebt.rayMul(L1.rayMul(U1)) - scaledDebt.rayMul(L0.rayMul(U0))`, split it into
liquidity/underwriter shares, and assign the rounding remainder to one side so
`liquidity + underwriter == total`. This makes `sum(totalDebt) == creditBackedSupply` an exact
identity. Second-order: the split between lenders and underwriters moves by <= 1 wei per accrual;
nothing else changes. Alternatively (defensive, not a substitute), make `burnCreditBacked` and
`recognizeBadDebt` clamp the decrement at `creditBackedSupply` instead of underflowing, so a wei
mismatch cannot block a repayment or a write-off; that hides the drift rather than fixing it.
**Invariant broken:** I3 (`sum(market.totalDebt()) == creditBackedSupply`), in the harmful direction.

---

### [LOW] `Vault.deposit` mints ERC-6909 before collecting the asset; a sender-side callback token can withdraw other depositors' tokens mid-call (I12 broken inside the transaction)
**Location:** `contracts/cap/Vault.sol:L34-L37` (`deposit`)
**Impact:** Between `_mint` and the completion of `safeTransferFrom`, the depositor holds a fully
spendable ERC-6909 balance for tokens the vault has not received. With an ERC-777-style asset
(hook on the *sender* before balances move) the depositor can, inside the hook, `withdraw` the same
amount against the vault's existing balance - i.e. take another depositor's tokens - or transfer
the ERC-6909 into a tranche/underwriter. With an honest, non-fee, non-rebasing token the outer
`transferFrom` still lands afterwards, so the end-of-transaction state reconciles and the attacker
nets nothing (test below shows `6909 supply 200e18 vs token balance 100e18` inside the window, and
`100e18 / 100e18` at rest). The accounting consequence is therefore confined to the window: any
contract that reads `Vault.balanceOf`/`totalSupply` or a tranche's `totalAssets` *during* another
contract's deposit sees an inflated figure. With a fee-on-transfer token the discrepancy is
permanent - documented as out of scope in `IVault.sol:L9-L13` and left to listing policy.
**Likelihood:** Requires a collateral token with sender-side transfer hooks to be listed for a
tranche (listing is permissioned), and a contract in the protocol that acts on vault balances
mid-deposit. I found no such reader inside the protocol; `Tranche.deposit` pulls via
`Vault.transferFrom` and is itself role-gated. Cost to attacker: zero, but so is the payoff with an
honest token. Could not demonstrate a net gain, hence Low.
**Exploit path:** (window demonstration, not a profit)
1. Victim deposits 100 of token T. 2. Attacker deposits 100 T; T calls attacker's hook before
moving balances. 3. In the hook attacker holds 100 ERC-6909, vault holds 100 T (victim's);
attacker `withdraw(T, 100)` -> vault sends the victim's 100 T. 4. Hook returns, `transferFrom`
pulls the attacker's 100 T. Net: zero for the attacker; the vault was empty for the duration of step 3.
**Proof:** `audit/tests/scratch/A/VaultCallback.t.sol::test_mintBeforeTransfer_windowLetsDepositorWithdrawOthersTokens`
(passes - it asserts the window exists and that the rest state reconciles):
```
[PASS] test_mintBeforeTransfer_windowLetsDepositorWithdrawOthersTokens() (gas: 500183)
```
**Recommendation:** Transfer first, mint second (OZ's own `ERC4626._deposit` ordering and comment
at `ERC4626Upgradeable.sol:L274-L281`). For belt-and-braces against fee-on-transfer, mint the
measured balance delta. No second-order effect.
**Invariant broken:** I12 (transiently, within one transaction). Holds at rest.

---

## Hypotheses tested and NOT broken (with what was tried)

### H6 - bad-debt curve split-equivalence, round-trip, monotonicity, decimals (I10, I11) - SURVIVED at the wei level
The NatSpec at `Stablecoin.sol:L193-L220` claims `k = B/(S*A)` is conserved and splitting is
"exactly equal, not equal up to dust". In reals it is: with `k = 1/A - 1/S`, a redemption maps
`A' = r/(1 + k r)` where `r` is the remaining supply, and `k' = 1/A' - 1/r = k`. Under integer
rounding it is *not* exactly equal but the inequality points the safe way: `retained` is rounded
up, so `A'_int >= A'_exact`, so `k` is **non-increasing** through every redemption. For an
`n`-leg exit ending at the same `S'`, `A'_n >= A'_exact` and `A'_1 = ceil(A'_exact)`; since
`A'_n` is an integer `>= A'_exact`, `A'_n >= A'_1`, so an `n`-leg payout is `<= ` the 1-leg
payout at 18 decimals. At lower decimals the payout floor to underlying units can let a split beat
the single call by at most **one underlying unit** (1e-6 USDC) when the exact payout sits on a unit
boundary. Tested at 6/8/18 decimals, 3000 runs each (`Curve.t.sol`):
- `testFuzz_splitNeverBeatsWhole` - n in [2,12] random slices vs one call: `split <= whole + 1 unit`, and `k` never increases after any slice. PASS.
- `testFuzz_roundTripNeverProfits`, `testFuzz_mintRedeemRoundTripNeverProfits` - fresh depositor during any shortfall (B in [0, C]) and with no shortfall, `deposit`/`mint` then `redeem(max)`: balance never rises. PASS (I11).
- `testFuzz_topUpBeforeExitNeverHelps` - the L219-220 claim ("depositing to improve an exit does not work"): `deposit d` then `redeem(x + d)` never nets more than `redeem(x)`. PASS. Analytically: the top-up lowers `k` to `B/((S+d)(A+d))` so `A_final` rises, and payout `(A+d) - A_final' - d < A - A_final`.
- `testFuzz_previewRedeemMonotone` - `previewRedeem`, `previewWithdraw` non-decreasing over the full share domain including the `_shares >= supply` boundary. PASS.
- `testFuzz_previewInversesFavourVault` - `previewWithdraw(previewRedeem(x)) <= x` and `previewRedeem(previewWithdraw(a)) >= a`, plus the live `withdraw(a)` burns exactly `previewWithdraw(a)` and moves `totalAssets` and the reserve by exactly `a`. PASS. (So the withdraw and redeem paths cannot be arbitraged against each other.)
- `testFuzz_ratioNeverFallsForStayers` - `A'/S' >= A/S` after every redemption. PASS (the peg-repair claim).
- `testFuzz_nearTotalShortfall` - `B` up to 1e12 x deposit, ratio -> 0, all `x` in [1, unlocked]. PASS; no revert, no over-payment.
Overflow/underflow in the curve: `anchor - retained*shortfall` cannot underflow because `retained <= A-1`, `B <= S`, so `(A-1)B < AS`; denominators are non-zero when `B>0`. `mulDiv` results are bounded by `remaining`/`retained` so cannot overflow 256 bits. The `_shares >= supply` branch of `_convertToAssets` is unreachable through any real redeem (bounded by `U < S` whenever `B > 0`); it only serves views.

### H1 - yield is minted unbacked (I1) - CLAIM SURVIVED; characterised
I1 holds **with equality** (`R == U`) through borrow, 365 daily accruals, deposit, redeem, write-off,
haircut redeem and cover (`Reserve.t.sol::test_yieldMintsDoNotMoveReserveOrUnlocked`,
`::test_writeOffThenRedeemThenCoverReconciles`, `Curve.t.sol::testFuzz_reserveIdentity`). Minted
yield moves `S` and `C` together and touches neither `R` nor `U`. There is **no state in which the
contract reports redeemable supply it cannot pay.** What decays is the *fraction* of supply that is
redeemable at any instant, `U/S = 1 - C/S = 1 - utilization`; e.g. 400 borrowed against 1000
deposited at the default slopes gives `U/S` 0.714 -> 0.656 after one year (utilization ray
0.3437e27 in the log). Yield-cUSD only becomes redeemable when a borrower repays with cUSD acquired
*by depositing* (which adds `R`) or when other depositors arrive; a repayment with cUSD bought on
the secondary market shrinks `S` and `C` without moving `R`, which is consistent. This is a
fractional reserve by design, not a defect; the solvency question is a redemption-flow question
(WS-G `reserve_decay.py`), not an I1 question.

### `previewDeposit` at par during a shortfall - CLAIM SURVIVED
The comment at `L154-L161` argues par-mint is required so a liquidator cannot buy cUSD below par
from the protocol and burn it at face value. I tried the other directions: a depositor-then-redeemer
never profits (I11 tests); a top-up never improves an exit; a `coverBadDebt` caller who mints at
par and covers pays exactly `$1` per `$1` of shortfall retired (`_checkIdentity` after cover in
`testFuzz_reserveIdentity`); a borrower who borrows at par and sells below par owes face value and
loses on liquidation. The only actor who benefits from cUSD trading below par is a *secondary-market*
buyer who liquidates, and their gain comes from the seller, as the NatSpec says. No in-protocol
profit path found.

### `recognizeBadDebt` underflow / `mint`/`burnCreditBacked` ordering desync (I3)
This is the Low finding above. Ordering is fine (every market path mints/burns exactly what it
records); the desync is rounding, and it is exactly what makes `creditBackedSupply -= _amount`
underflow. Fixed markets hold I3 exactly.

### `coverBadDebt` griefing / front-running - NOT EXPLOITABLE IN-PROTOCOL
`coverBadDebt` is `restricted` and wired to GOVERNOR in production
(`contracts/deploy/service/ConfigureAccessControl.sol:L54-L57`); nothing else can call it and no
market calls it (grep: only the interface, the contract and tests). There is nothing to front-run
on-chain: deposits are at par (>= market price) and redemptions are below the ratio, so a searcher
who knows a cover is coming can only buy cUSD off-chain. The queue cannot be un-queued, and queued
claims are priced at claim time, so a queued redeemer who waits for the cover simply gets par.

### `unlockedSupply() == 0` state
Reached exactly when `R` is fully drained (`test_yieldMintsDoNotMoveReserveOrUnlocked`: depositor
redeems `maxRedeem`, then `unlockedSupply == 0` and the yield holder's `maxRedeem == 0`). A redeemer
then sees `maxRedeem == 0`, `redeem` reverts `ERC4626ExceededMaxRedeem`, `requestRedeem` succeeds
and queues, `claimableRedeemRequest == 0`, and `previewRedeem(x)` still returns the curve value
(a quote that cannot be filled - see Informational). The `supply <= locked` guard only fires
at exactly `S == C + B` because `S - C - B >= 0` is preserved by construction (I2 by construction:
every path that lowers `S` lowers `C` or `B` by the same amount or is bounded by `U`).

---

## Rounding inventory (every division in scope; direction; who it favours)

| Location | Expression | Direction | Favours |
|---|---|---|---|
| `Stablecoin.sol:L105` `_utilizationRate` | `credit.rayDiv(supply)` | half-up | neutral; cannot exceed 1e27 since `C <= S` |
| `L168` `previewDeposit` | `mulDiv(assets, 1e18, 10^ud, Floor)` | exact for `ud <= 18` | neutral |
| `L185` `previewMint` | `mulDiv(shares, 10^ud, 1e18, Ceil)` | up | vault (minter overpays `< 1` unit) |
| `L244` `_convertToAssets` retained | `mulDiv(r, anchor, anchor + r*B, opposite)` | up for redeem (Floor) | vault: redeemer paid `<= exact` |
| `L248` `_convertToAssets` scale | `mulDiv(value, 10^ud, 1e18, rounding)` | down for redeem | vault: `< 1` unit stranded in `R` per redeem |
| `L264` `_convertToShares` scale | `mulDiv(assets, 1e18, 10^ud, rounding)` | exact for `ud <= 18` | neutral |
| `L275` `_convertToShares` remaining | `mulDiv(retained, anchor, anchor - retained*B, opposite)` | down for withdraw (Ceil) | vault: more shares burned |
| `L313` `_onWithdraw` paidInShares | `mulDiv(assets, 1e18, 10^ud)` | exact | neutral; bad debt retired by `>= exact` (stayers) |
| `L315` `_onWithdraw` cap | `min(reduced, badDebt)` | - | stayers (extra dust stays in `R`) |
| `ERC7540AsyncRedeem.sol:L129` | `settledQueue + unlockedSupply()` | - | - |
| `Vault.sol` | none | - | - |

Every direction in `Stablecoin` favours the vault or the remaining holders; no direction favours the
redeemer. The only redeemer-favouring wei is the cross-decimal one-unit boundary case in split vs
whole, documented under H6.

---

## Informational

**I-1. `IStablecoin.coverBadDebt` NatSpec promises a route that does not exist.** `L73-L74` says
it is "for a treasury *or a market that later recovers written off debt*". No market calls it, no
market holds GOVERNOR, and after `FixedMarket.writeOff` sets `debt[id] = loanDebt - amount` the
borrower can no longer even repay the written-off portion. A later recovery can only flow back
through a GOVERNOR who holds cUSD. Either wire a market route or fix the comment.

**I-2. Utilization excludes `badDebt`, so a write-off lowers the liquidity rate protocol-wide.**
`utilizationRate = C/S` and `recognizeBadDebt` moves `_amount` from `C` to `B`, so every write-off
drops utilization and hence every market's liquidity index rate (`InterestRateModel._updateLiquidityRate`),
while the reserve fraction `R/S` is unchanged. Lenders' yield falls at the moment they have taken a
loss, and borrowers get cheaper. The economically consistent measure of reserve scarcity is
`(C + B)/S = 1 - R/S`. Design choice; flag for WS-E/WS-G.

**I-3. Redemption liveness is coupled to the IRM never reverting.** `_deposit`, `_onWithdraw`,
`mintCreditBacked`, `burnCreditBacked`, `recognizeBadDebt`, `coverBadDebt` all call
`IInterestRateModel(irm).updateLiquidityRate()`; `irm` is set once in `initialize` with no setter.
A reverting IRM (e.g. `_index` overflow from unbounded slopes, H8/WS-E; or an IRM upgraded to a
new proxy address) bricks every deposit and redemption of cUSD. Consider a try/catch or a setter.

**I-4. `totalAssets()` returns share units, not asset units.** Documented in `IStablecoin.sol:L100-L103`,
but it breaks the ERC-4626 expectation that `totalAssets` is denominated in `asset()` decimals. For
a 6-decimal underlying an integrator comparing `totalAssets()` to `asset.balanceOf(vault)` is off by
1e12. Internally harmless (all conversions are overridden).

**I-5. `previewRedeem`/`convertToAssets` quote amounts that cannot be filled when `unlockedSupply`
is short.** ERC-4626 permits this only if `maxRedeem` is honoured, which it is, but `previewRedeem(x)`
for `x > maxRedeem` returns the curve value rather than reverting or clamping; integrators that
quote off `previewRedeem` alone will overstate what is claimable. `activeAssets()` likewise prices
`activeSupply` through the curve even when most of it is credit-backed.

**I-6. `_convertToShares` returns `supply` for `value >= backing`, which is not the true inverse
when `B > 0`** (`previewWithdraw(A)` says "all shares" but a real redeem of all shares is
impossible while `C > 0`). Unreachable through `withdraw` because `maxWithdraw < A`; view-only
oddity.

---

## Invariants

**Broken:**
- **I3** - `sum(market.totalDebt()) == creditBackedSupply()` fails by a wei-level random walk on
  floating markets; harmful direction reachable (finding 1). Fixed markets hold it exactly.
- **I12** - holds at rest; broken *within* a `Vault.deposit` transaction for callback tokens
  (finding 2).

**Confirmed (tight):**
- **I1** holds with equality, `R == U`, modulo `< 10^(18-ud)` wei of stranded dust per redemption
  in the vault's favour. Suggest strengthening the invariant handler to
  `R >= U && R - U <= redemptions * 10^(18-ud)`.
- **I2** holds by construction (every path preserves `S - C - B >= 0`).
- **I4** `badDebt` decreases only in `coverBadDebt` and `_onWithdraw`; the `_onWithdraw` decrement is
  `min(shares - paid, badDebt)` so cannot underflow.
- **I10** holds as `split <= whole + 1 underlying unit`; exact (`<=`) at 18 decimals.
- **I11** holds for `deposit`->`redeem` and `mint`->`redeem`, with and without bad debt.

**New invariants the code implies that the plan missed:**
- **I17 (k monotone):** `badDebt / (totalSupply * totalAssets)` is non-increasing across every
  redemption (strictly, rounding can only lower it). This is the real form of the "conserved k"
  claim and is the right handler target - equality is not achievable in integers.
- **I18 (ratio monotone):** `totalAssets/totalSupply` never falls across a redemption, and never
  falls across `coverBadDebt`; it *does* fall across `burnCreditBacked` (repay/liquidate) while
  `badDebt > 0`, which is expected and should be asserted as the only path that lowers it.
- **I19 (preview inverses):** `previewWithdraw(previewRedeem(x)) <= x` and
  `previewRedeem(previewWithdraw(a)) >= a` for all `x <= maxRedeem`, `a <= maxWithdraw`.
- **I20 (settlement identity):** for every redemption, `delta totalAssets == delta reserve ==
  paid`, and `delta badDebt == min(shares - paid, badDebt)`.

## Appendix: gas & style
- `Stablecoin.sol:L94-L97` `supplies()` and `L84-L86` `utilizationRate()` both read `totalSupply()`; the IRM calls `supplies()` then the stablecoin calls `utilizationRate()` in the same `updateLiquidityRate` - one extra SLOAD pair per update.
- `_convertToAssets` computes `supply * backing` (`anchor`) and `_convertToShares` recomputes it; trivially cacheable in a struct if these ever get hot.
- `IStablecoin.sol:L122` says "Overrides IERC7540AsyncRedeem unlockedSupply" - it overrides `ERC7540AsyncRedeem`, the interface declares nothing to override.
