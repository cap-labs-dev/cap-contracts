# LEAD-2 verification — fixed draws pay catch-up on floating notional; same-block floating sandwich reprices a victim

**Verdict:** CONFIRMED (Medium stands), with three corrections to the write-up and one of the two recommendations shown to be ineffective.

## What I checked (HEAD a843c1d)

Read end to end: `contracts/cap/market/FixedMarket.sol` (`_borrow`, `_borrowPremium`, `availableCredit(term)`, `_premium`), `contracts/cap/InterestRateModel.sol` (`unsmoothedCredit`, `averageUtilizationAfterMint`, `fixedRatesAfterMint`, `_accrueAverage`, `_updateLiquidityRate`), `contracts/cap/market/FloatingMarket.sol` (`borrow`, `repay`, `_borrowWithin`, `_repayWithin`, `_chargePremium`, `index`), `BaseMarket._chargePremium`, `Stablecoin._mintCreditBacked/burnCreditBacked/fundCreditBacked`, `PremiumVesting._fund`. Ran the author's PoC (reproduces exactly: 10,787.67 / 11,472.60 / 11,130.14 / 12,271.69; `Expected_P6` FAILS on HEAD as claimed) and wrote an independent suite.

## Strongest attacks on the finding, and why they did not land

**1. "This is documented marginal pricing, not a bug."** `IFixedMarket.premiumForBorrow` natspec says "Incremental in unsmoothed credit", `availableCredit(term)` says "A same-window draw already minted is in the rate via {unsmoothedCredit}; the catch-up is the incremental premium on that prior notional", and `test/integration/AccountingIntegrity.t.sol::test_partitionedFixedBorrowPaysTheUndividedPremium` pins split-invariance. So charging `f(prior+P) − f(prior)` on *global* unsmoothed credit is intended-as-written. It does not rescue the finding because the only stated justification for the catch-up (a split draw must not be cheaper than an undivided one) is about notional that **locked its rate upfront**. Floating notional does not: `Stablecoin._mintCreditBacked` calls `updateLiquidityRate()` on every mint, so the moment the fixed draw mints, `liquidityData.ratePerYear` is re-read from live utilization and the floating index accrues at `r(C+P)` from then on (V5: live liquidity rate 0.0625 → 0.07099 on the fixed mint). The pot is therefore paid `C·T·(r(C+P)−r(C))` twice — once upfront by the fixed borrower, once through the floating index — and the fixed borrower's bill depends on whether a third party's floating draw landed 1 minute or 2 hours ago (V5: 11,472.60 vs 11,130.14, and the 342.47 difference equals `C·T·(r(C+P)−r(C))` to the wei). No design note covers that. Control V6 shows a *fixed* prior of the same size produces the same catch-up (347.10), confirming the mechanism is generic to `unsmoothedCredit` and the floating-specific problem is exactly the two properties the author names: the prior reprices on its own, and it can leave for free.

**2. "The same-block early return in `_chargePremium` is the crux; it is a one-line fix."** It is not the crux. `_chargePremium` returning early on `lastPremiumUpdate == block.timestamp` is irrelevant: with zero elapsed time `_growIndex` returns `lastLocal` anyway, so the premium would be zero with or without the early return. V3 holds the floating draw for one 12-second block instead: attacker cost 0.214 cUSD, victim overcharge 1,482.12 vs 1,484.02 same-block (99.9%, the 1h EMA absorbs ~0.3% per 12s). So the attack needs neither a bundle nor same-block ordering, and the author's second recommendation ("drop the early return, or compute premium for elapsed == 0 at the post-mint rate") does nothing against the realistic variant. Likelihood is, if anything, higher than stated.

**3. "A check elsewhere bounds it."** `availableCredit(term)` deducts the catch-up from the limit, which keeps I32 (`debt ≤ creditLimit`) intact but is itself a second griefing surface: the sandwich shrinks `availableCredit(30d)` from 2,442,833 to 2,439,228, so a victim who sized a max draw off the pre-sandwich figure reverts `InsufficientLiquidity` (V4). `FixedMarket.borrow(recipient, principal, term)` has no `maxPremium`/slippage argument, so the victim has no on-chain guard. `healthiness() < 1e27` can also flip a near-max draw into a revert. Nothing blocks the path.

**4. Precondition.** The attacker needs a floating borrower role with an unused line ≥ C on *any* floating market (not the victim's market), and the round-trip requires only that they hold C cUSD for one block. Borrower roles are whitelisted but, under the brief's stance, borrowers are third parties. Holds.

## Corrected numbers

- **The +13.8% (1,484.02 on a 2M/500k sandwich) is two mechanisms, not one** (V1):
  - 913.24 (61.5%) is the victim being priced at `util(C+P)` instead of `util(P)` — `averageUtilizationAfterMint` adds unabsorbed credit **in full**, so a transient floating draw bypasses the EMA on the up side. This is not the catch-up.
  - 570.78 (38.5%) is the catch-up `C·T·(r(C+P)−r(C))` on the floating notional — the double charge proper.
  - The honest-case +342.47 (+3.1%) is 100% catch-up (V5).
- **The surplus goes to stcUSD (opted-in) holders only, not tranches.** The underwriter rate is a flat per-market number, so `uwRate == uwRate0` and the catch-up on the underwriter leg is exactly zero (1 wei rounding, V1). All 1,484.02 is liquidity premium → `fundCreditBacked` → 12h vest to opted-in stcUSD holders pro rata.
- **Profitability.** An attacker holding share `s` of opted-in stcUSD recovers `s × 1,484` per victim draw; net-positive for `s ≳ 0.5%` on this book at mainnet gas. So it is not pure griefing — a sizeable staker who also holds an idle floating line profits at zero risk — but the gain per victim is small and shared.
- **Bound.** Overcharge `= T·[P·(r(C+P)−r(P)) + C·(r(C+P)−r(C))]`, with `util(x) = x/(S+x)`, `S` = non-credit cUSD supply. `C` is bounded by the attacker's total unused floating credit, not by the victim's `fixedCreditLimit`. Below the kink the catch-up term peaks and then decays in `C` (≈ `P·S·slope0/kink / C` for large `C`); crossing the kink is where it gets large: with a 10M line against the same 2M reserve, victim premium 10,787.67 → 15,890.41, **+47.3%** (V7). The 13.8% figure is representative of a below-kink book; it is not the ceiling.
- The floating "repaid 1,999,999.999…" is the `_borrowWithin` floor rounding on the mint, not a premium; repaid == minted exactly and the attacker's cUSD balance is unchanged (V2).

## Existing coverage

None. `AccountingIntegrity.t.sol` split-invariance tests use one borrower's own fixed draws; `test/unit/cap/InterestRateModel.t.sol` (`test_averageAfterMint_countsUnabsorbedCredit`, `test_unsmoothedCredit_doesNotFollowALiveDrop`) exercise the IRM against a mock and never assert anything about a fixed premium vs. floating notional. No test pins "a fixed premium is independent of transient third-party notional".

## Independent test

`audit/v3/tests/scratch/verify/LEAD-2/LEAD2_Verify.t.sol` — `FOUNDRY_TEST=audit/v3/tests/scratch/verify/LEAD-2 forge test --match-path 'audit/v3/tests/scratch/verify/LEAD-2/*' -vv`

```
Ran 7 tests for audit/v3/tests/scratch/verify/LEAD-2/LEAD2_Verify.t.sol:LEAD2_Verify
[PASS] test_V1_decomposeSandwichOvercharge() (gas: 477345)
Logs:
  victim premium clean: 10787.671232876712328766
  victim premium sandwiched: 12271.689497716894977169
  overcharge total: 1484.018264840182648403
    of which: priced at util(C+P) not util(P): 913.242009132420091324
    of which: catch-up on floating C: 570.776255707762557078
  overcharge in liquidity premium: 1484.018264840182648402
  overcharge in underwriter premium: 0.000000000000000001

[PASS] test_V2_sameBlockAttackerPaysNothing() (gas: 848257)
[PASS] test_V3_oneBlockHoldCostsDustAndStillReprices() (gas: 1170317)
Logs:
  attacker cost for a 12s hold: 0.214041047151877084
  victim overcharge same-block: 1484.018264840182648403
  victim overcharge 12s later: 1482.118571334488986714

[PASS] test_V4_sandwichRevertsAVictimSizedBeforeIt() (gas: 628416)
Logs:
  availableCredit(30d) before: 2442833.240379252649191299
  availableCredit(30d) after sandwich: 2439228.295819935691318328

[PASS] test_V5_honestFloatingDrawIsPureCatchUpAndFloatingReprices() (gas: 993394)
Logs:
  quote with C unabsorbed: 11472.602739726027397260
  quote with C absorbed: 11130.136986301369863015
  difference: 342.465753424657534245
  C*T*(r(C+P)-r(C)): 342.465753424657534246
  live liquidity rate before fixed draw: 0.062500000000000000000000000
  live liquidity rate after fixed draw: 0.070992068004776255188491496

[PASS] test_V6_controlFixedPriorSameCatchUp() (gas: 3703849)
Logs:
  prior fixed C (incl. its premium): 510787.671232876712328766
  second borrower's own premium at r(C+P): 11136.272271083760076474
  plus catch-up on prior fixed C: 347.103263849341684275

[PASS] test_V7_aboveKinkOverchargeFraction() (gas: 692693)
Logs:
  util(C) after 10M draw: 0.833333333333333333333333319
  victim premium clean: 10787.671232876712328766
  victim premium sandwiched: 15890.410958904109589040
  overcharge bps of clean: 4730

Suite result: ok. 7 passed; 0 failed; 0 skipped
```

Author's PoC re-run on HEAD: `P6_FixedCrossNotional` 2/2 PASS with the quoted figures; `Expected_P6::test_EXPECTED_fixedPremiumIndependentOfSameBlockFloatingNotional` FAILS `12271689497716894977169 != 10787671232876712328766`.

## Severity

Medium is right. Impact is bounded to a fraction of the *premium* (3% honest, 14% on the author's book, 47% across the kink), never principal, and it needs a whitelisted floating borrower with an idle line; but the cost is dust, it repeats on every victim draw, the victim has no on-chain guard, honest fixed borrowers are systematically overcharged whenever any floating draw is recent, and a large opted-in staker nets a profit. Not High (bounded, attacker-side precondition, small per-victim gain); not Low (zero-cost, unguardable, repeatable, plus a DoS corollary).

## Recommendation to the lead

**Keep at Medium, re-word.** (1) Split the impact into its two mechanisms — the catch-up on floating notional (pure double charge, 100% of the honest case, ~38% of the sandwich) and the full-weight inclusion of unabsorbed credit in `averageUtilizationAfterMint` (transient-utilization pricing, ~62% of the sandwich) — because they need different fixes and the current text attributes all of it to the catch-up. (2) Replace "stakers and tranches" with "opted-in stcUSD holders only" (uw catch-up is identically zero). (3) Drop the "same-block early return" framing and the "drop the early return" recommendation — a one-block hold costs 0.21 cUSD and gets 99.9% of the effect; interest is time-based so no same-block premium exists to charge. (4) Add the corollary that `availableCredit(term)` shrinks under the sandwich, so a pre-sized max draw reverts (zero-cost DoS), and that `borrow` has no `maxPremium`. Fix guidance: track unsmoothed *fixed* credit separately in the IRM (fixed markets report their own mints) and use it for both the `_borrowPremium` catch-up and the `availableCredit(term)` deduction; for the transient-utilization leg note the genuine tension (excluding floating unabsorbed credit from the projected utilization would under-price a legitimate fixed draw made right after a genuine floating draw), and recommend a caller-supplied `maxPremium` on `borrow`/`borrowMore`/`extend` as the cheap, complete mitigation of the adversarial case.
