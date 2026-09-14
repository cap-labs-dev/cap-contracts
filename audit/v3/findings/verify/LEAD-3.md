# LEAD-3 verification — owner zeroes a locked third-party junior's premium weight while it stays first-loss

**Verdict:** CONFIRMED-AT-LOWER-SEVERITY — **Low**, as a named sibling of L-21 (`setUnderwriterRate(0)`, documented "no lower bound"). Every mechanical claim holds on HEAD and the PoC below proves it end to end (weight 0 accepted, junior locked and unable to exit, senior takes 100% of the underwriter premium, junior slashed first and wiped). What does not hold is the Medium: the marginal harm over the already-documented owner lever is the junior's *weight share* of the premium, which at the harness' reference weights is 0.83 cUSD per 30 days per 1,000 of capital (≈1.0% APR), against a 1,000 first-loss exposure the junior accepted when it deposited. The proposed invariant I43 is also vacuous as written: weight 1 wei pays exactly 0 too.

## What I checked (HEAD a843c1d)

Read end to end: `contracts/cap/market/BaseMarket.sol` (`setTrancheWeights`, `_setTranches`, `_chargePremium`, `_earnsPremium`, `_liquidate`, `lockedValue`, `maxLiquidatable`), `contracts/cap/market/FloatingMarket.sol` (`borrow`, `liquidate`, `chargePremium`, `_chargePremium`, `_premium`), `contracts/cap/Registry.sol::createTranche` / `createFloatingMarket`, `contracts/cap/Tranche.sol` (`unlockedSupply`, `slash`), `contracts/utils/PremiumVesting.sol` (`claimable`, `optIn`/`optOut`, `_fund`), `contracts/cap/Underwriter.sol` (`deallocate`, `deallocateAsync`, `finalizeDeallocateAsync`), `contracts/cap/InterestRateModel.sol::updateUnderwriterRate`, `contracts/interfaces/IBaseMarket.sol` NatSpec, `test/integration/RoleTable.t.sol` (role map). No PoC existed; I wrote one.

## Strongest attacks on the finding, and why they did or did not land

**1. "Weight 0 is rejected somewhere."** Did not land. `_setTranches` checks non-zero address, `market()` match, no duplicates, Σ == 1e27, and `healthiness() >= 1e27`; there is no per-tranche floor. `test_V1_zeroWeightAcceptedEverywhere`: `setTrancheWeights([1e27, 0])` on a funded, locked market succeeds; `[1e27-1, 1]` succeeds; `Registry.createTranche` appends a new most-junior tranche at weight 0; `Registry.createFloatingMarket` accepts `[1e27, 0]` at creation. The healthiness check is irrelevant to the attack (the owner acts while healthy).

**2. "The junior can exit or opt out of the slash."** Did not land. `test_V2`: with 1,000 debt on [1,000 senior, 1,000 junior] at lt 0.8/buffer 0.1, `lockedValue(junior)` = 1,428.57 > its 1,000 capital, so `unlockedSupply() == 0`, `maxRedeem == 0`, `maxInstantRedeem == 0`; `instantRedeem` reverts, a queued request has `claimable == 0` now and after 30 days; `optOut` only stops earning and changes neither the lock nor the slash order. A real Underwriter position is no better (`test_V9`): `deallocate` short-fills to 0, `deallocateAsync` queues, `finalizeDeallocateAsync` reverts now and after 30 days. The lock lasts as long as the debt, which an owner-borrower can roll indefinitely.

**3. "This is a documented owner prerogative."** Partially lands. `IBaseMarket.setTranches` NatSpec: "Restricted to the registry; market owners may only change weights." `setTrancheWeights` NatSpec says only "Set the tranche weights … in ray decimals". `RoleTable.t.sol` pins `setTrancheWeights`, `setUnderwriterRate`, `setLtv` to the owner role. No AccessManager execution delay is configured anywhere in `Registry` (grep `delay` → nothing), so a junior gets no warning. Under the third-party stance this *is* a trust assumption the junior/allocator takes on the owner, and it is the same assumption they already take via `setUnderwriterRate(0)`, whose NatSpec (`InterestRateModel.sol:123`) says outright "There is no lower bound: a market may set its underwriter rate to zero". `test_V7`: rate 0 → junior 0, senior 0, junior still locked and first-loss. LEAD-3 differs from L-21 in exactly one respect: the owner's senior keeps the junior's share instead of nobody getting it. So the *new* harm LEAD-3 introduces is bounded by the junior's weight × underwriter premium.

**4. "The numbers are small."** Lands, and it is what demotes this. `test_V3` at harness defaults (20% underwriter APR, 1,000 debt): 30-day underwriter premium 16.574 cUSD; at weight 0 the junior receives 0 and the owner's senior 16.574 (claimable 16.5742 after vesting). Counterfactual at the reference 5% junior weight: **0.829 cUSD per 30 days, ≈ 1.008% APR on 1,000 capital**. The junior's exposure in the same book (`test_V4`): a 40% collateral drop makes the market unhealthy (0.944); a 200 repay slashes **340 tokens = 204 USD entirely from the junior, senior 0**; a full clip (715.9) wipes the junior to 0 and kills it, and only then takes 217 tokens off the senior. "Junior premium earned to date: 0". The picture is right, but the asymmetry between 0.83/month of lost reward and 1,000 of first-loss exposure existed *before* the weight change — a 5% weight already priced the junior at ~1% APR for first-loss on 50% of the book. Zeroing it removes ~1% APR; it does not create the exposure. `config/cap-v2.json` carries no production weights, so 95/5 (harness) is the only reference split.

**5. "The proposed invariant I43 fixes it."** Refuted as worded. `test_V6`: weight 1 wei → `underwriterPremium.rayMul(1)` floors to 0, senior still takes everything; weight 1e-7 of a ray pays 1.68e-6 cUSD. "No tranche with locked capital has weight 0" is satisfiable with economically identical outcomes; any floor has to be a meaningful fraction (bps), and it then has to be reconciled with the already-unfloored rate.

**6. Owner-as-borrower.** `test_V8`: with the owner also the borrower, the 30-day debt growth of 16.574 flows entirely back into the owner's own senior; the junior stands first-loss for 1,000 and receives nothing. Caveat: the harness default has `applyLiquiditySlopes = false`, so `liquidityRate == 0` and the liquidity leg is 0 in V3/V8; in production the liquidity premium goes to cUSD stakers, so the owner-borrower's net cost is the liquidity leg, not zero. This is the most defensible framing of LEAD-3 ("free first-loss cover from a captive junior") and it is still a Low: the junior consented to first-loss under an owner who could already set its rate to zero.

**7. Family context (`test_V10`).** The owner has a lever that raises the junior's *risk* after lock, not just cuts its reward: `setLtv(0.7)` (max: ltv + buffer ≤ lt) plus a redraw takes healthiness 1.60 → 1.14. Note V10's redraw needed the harness' GOVERNOR role to lift the 1,000 fixed credit limit; the owner-only version applies when the fixed limit is not binding. Worth a sentence in the L-21 family, not a separate finding.

## Corrected numbers

- Harness reference book: senior 1,000 (owner's capital), junior 1,000 (third party), debt 1,000, lt 0.8, buffer 0.1, bonus 2%, underwriter rate 20% APR, weights 95/5.
- `lockedValue(junior)` 1,428.571 USD, `lockedValue(senior)` 428.571 USD.
- 30-day underwriter premium: 16.574206 cUSD (continuous compounding of 20% × 30/365). Junior at weight 0: 0. Senior: 16.574206. Junior counterfactual at 5%: 0.828710 (≈1.008% APR). Junior at weight 1 wei: 0. Junior at weight 1e20 (1e-7 of a ray): 1,684,886,618,173 wei.
- Liquidation at price 0.6: healthiness 0.9443, `maxLiquidatable` 715.94; 200 repaid → 204 USD / 340 tokens slashed, all junior; full clip → junior 0 (killed), senior 782.90 remaining.
- Under L-21 (`setUnderwriterRate(0)`): junior 0, senior 0, junior still locked. Marginal harm of LEAD-3 over L-21 = junior weight × underwriter premium = 0.83 cUSD / 30 d at reference weights.

## Existing coverage

`test/unit/cap/Lender.t.sol`, `test/integration/Rewarder.t.sol` (`test_setTrancheWeights_onlyAuthority`, `_invalidTotal_reverts`, `_byManager`) and `test/integration/DebtLifecycle.t.sol::test_setTrancheWeights_preservesMembership` cover authorisation, Σ == 1 ray and membership. Nothing asserts a per-tranche floor or that a locked tranche keeps earning, so no existing test contradicts or covers the finding.

## Independent test

`audit/v3/tests/scratch/verify/LEAD-3/LEAD3_Verify.t.sol` — `FOUNDRY_TEST=audit/v3/tests/scratch/verify/LEAD-3 forge test --match-path 'audit/v3/tests/scratch/verify/LEAD-3/*' -vv`

```
Ran 10 tests for audit/v3/tests/scratch/verify/LEAD-3/LEAD3_Verify.t.sol:LEAD3_Verify
[PASS] test_V10_ownerCanAlsoRaiseRiskAfterLock() (gas: 369763)
Logs:
  healthiness before setLtv: 1.600000000000000000000000000
  healthiness after setLtv(0.7) + redraw: 1.142857142857142857142857143
  debt now: 1400.000000000000000000

[PASS] test_V1_zeroWeightAcceptedEverywhere() (gas: 3203406)
Logs:
  no per-tranche floor in _setTranches, setTrancheWeights, createTranche, or createFloatingMarket

[PASS] test_V2_lockedJuniorCannotExitOrOptOutOfSlash() (gas: 870036)
Logs:
  lockedValue(junior) USD: 1428.571428571428571429
  lockedValue(senior) USD: 428.571428571428571429
  junior: instantRedeem reverts, async claim 0 now and after 30d, optOut changes nothing

[PASS] test_V3_ownerZeroesJuniorWeight_seniorTakesAll() (gas: 587011)
Logs:
  debt: 1000.000000000000000000
  liquidity rate (harness default): 0.000000000000000000000000000
  liquidity premium 30d -> cUSD stakers: 0.000000000000000000
  underwriter premium 30d: 16.574205994088589244
    junior receives at weight 0: 0.000000000000000000
    senior (owner) receives: 16.574205994088589244
    owner claimable after vest: 16.574192214393345181
  counterfactual junior at deploy weight 5%: 0.828710299704429462
  counterfactual junior APR at 5% weight (ray): 0.010082641979737225121000000
  junior first-loss exposure (USD): 1000.000000000000000000

[PASS] test_V4_juniorSlashedFirstWhileEarningNothing() (gas: 1278147)
Logs:
  healthiness: 0.944348178755169428311564222
  maxLiquidatable: 715.939533393112296210
  repaid: 200.000000000000000000
  slashed USD: 204.000000000000000000
  junior tokens lost: 340.000000000000000000
  senior tokens lost: 0.000000000000000000
  junior premium earned to date: 0.000000000000000000
  after full clip: junior assets: 0.000000000000000000
  after full clip: senior assets: 782.902793231709096445
  junior killed: yes

[PASS] test_V5_converseSeniorZero_juniorTakesAll() (gas: 484187)
Logs:
  [0,1e27] senior receives: 0.000000000000000000
  [0,1e27] junior receives: 16.574205994088589244

[PASS] test_V6_oneWeiWeightPaysZeroToo() (gas: 749026)
Logs:
  junior at weight 1 wei (wei): 0
  junior at weight 1e-7 (wei): 1684886618173
  premium that period: 16.848866181726974907

[PASS] test_V7_setUnderwriterRateZeroAlreadyZeroesJunior() (gas: 234601)
Logs:
  L-21 rate=0: junior: 0.000000000000000000
  L-21 rate=0: senior: 0.000000000000000000
  L-21 rate=0: liquidity premium still charged: 0.000000000000000000
  LEAD-3 differs from L-21 only in that the owner's senior keeps the junior's share

[PASS] test_V8_ownerBorrowerGetsFreeFirstLossCover() (gas: 3713608)
Logs:
  owner's debt growth 30d: 16.574205994088589244
    of which returns to owner's senior: 16.574205994088589244
    net cost of the junior's first-loss cover (liquidity leg only): 0.000000000000000000
  junior capital standing first-loss for that: 1000.000000000000000000

[PASS] test_V9_underwriterAllocatorCannotDeallocate() (gas: 5263422)
Logs:
  Underwriter: deallocate -> 0, deallocateAsync queued, finalize reverts now and after 30d

Suite result: ok. 10 passed; 0 failed; 0 skipped; finished in 10.57ms (14.00ms CPU time)
```

(The "liquidity premium 0" lines are the harness' `applyLiquiditySlopes = false` default, not a protocol property.)

## Recommendation to the lead

**Demote to Low and fold into the L-21 family** ("owner compensation and risk levers are unfloored, unilateral, undelayed, and usable after a junior is locked"), keeping LEAD-3 as the named variant in which the owner's own senior — or an owner-borrower, round-trip — keeps the junior's share. Re-word Impact to state the bound explicitly: the incremental harm over `setUnderwriterRate(0)` is `weight_junior × underwriterPremium`, ≈1% APR at the reference 95/5 split, against a first-loss exposure the junior already priced. Drop I43 as written (1 wei satisfies it and pays 0) and replace with either (a) a bps-level floor on any tranche with `totalCapital > 0` while `totalDebt > 0`, applied to both `setTrancheWeights` and `setUnderwriterRate` so one lever cannot route around the other, or (b) an AccessManager execution delay on the owner role's `setTrancheWeights`/`setUnderwriterRate`/`setLtv` long enough for an unlocked junior to leave — noting that a *locked* junior cannot leave regardless, so (b) only helps before lock. The recommendation "emit the change with old/new weights" is already half-met: `SetTranche(tranche, weight, index)` fires per tranche on every `_setTranches`; the old weight is the previous event. Do not keep at Medium: no fund loss, no new exposure, small bounded reward diversion, and the trust assumption on the owner is already documented in the IRM.
