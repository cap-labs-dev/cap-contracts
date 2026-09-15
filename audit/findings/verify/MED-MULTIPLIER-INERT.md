# MED-MULTIPLIER-INERT — verification

Finding under test: D1 in `audit/findings/D.md` — "[MEDIUM] FloatingMarket market multiplier is
economically inert; 1x and 2x markets charge identical premium to the wei".

## Verdict: DEMOTE to Low

## Why (one paragraph, the decisive reason)
The bug is real and I could not break it: with `liquidityIndex(m) = I(t).rayMul(m)`, a floating
borrow stores `scaled = P.rayDiv(I0·m·U0)` and reads back `scaled.rayMul(I(t)·m·U(t))`, so `m`
cancels at origination, and `setMarketMultiplier`'s re-index (`scaled = debt.rayDiv(I·m_new·U)`)
cancels it again on any mid-life change — the re-index that the comment sells as "non-retroactive"
is precisely what removes the only effect the multiplier could ever have on a floating market. A
256-run fuzz over the whole production band [1e27, 2e27] with a 10% underwriter rate and 1–12
charge cadences gives bit-identical debt to the 1x control; the interface natspec ("multiplier for
a market's liquidity interest **rate**", "reindexes scaled debt so outstanding **principal** is
unchanged") and the contrast with `fixedRatesAfterMint` (which multiplies the rate and works) settle
that this is a defect, not intent. But it is a non-functional pricing knob, not a loss: no actor
can profit from it, nothing is extractable, the parameter defaults to 1x in production
(`DeployInfra.sol:50` passes min=max-floor 1e27 and markets are created unset → 1x), and the harm
only exists after an OWNER deliberately raises it and then relies on it — at which point lenders
receive the base curve's yield rather than a surcharge. Under Immunefi's scale that is exactly
"contract fails to deliver promised returns, but doesn't lose value" = Low. (A C4-style rubric
would call a silently broken protocol function Medium; the brief asks for Immunefi-style.)

## What I tried (numbered; include commands run and real output snippets)

1. **Algebra with exact WadRayMath semantics.** `rayMul(a,b) = (a·b + RAY/2)/RAY`, `rayDiv(a,b) =
   (a·RAY + b/2)/b`, both half-up. Origination: `scaled = P·RAY/(I0·m·U0)`; reading:
   `scaled·(I·m·U)/RAY = P·(I·U)/(I0·U0)` up to one half-up rounding per op. `_premium` gives
   `liquidityPremium = scaled·U_prev·(L_cur − L_prev)` with `L = I·m`, so the `m` inside `scaled`
   cancels the `m` in the index difference. Mid-life: after `_chargePremium`, `scaled' = debt·RAY/
   (I·m_new·U)` and future readings are `debt·I(t)U(t)/(I·U)` — `m_new` is gone. Only *not*
   re-indexing would have produced an effect (a one-time principal jump of `m_new/m_old`), which is
   a repricing of principal, not of rate, and the comment is right to reject it. Confirmed.

2. **Ran the PoC.**
   ```
   FOUNDRY_TEST=audit/tests/scratch/D forge test --match-path 'audit/tests/scratch/D/D1_MultiplierInert.t.sol' -vv
   [PASS] test_fixedMultiplierWorks_forContrast()
     fixed premium 1x: 16438356164383561643
     fixed premium 2x: 32876712328767123287
   [FAIL: 2x multiplier must charge materially more liquidity premium: 221332933560973813056 <= 331999400341460719584] test_floatingMultiplierChangesNothing()
     premium at multiplier 1x    : 221332933560973813056
     premium at multiplier 2x    : 221332933560973813056
   [FAIL: 2x multiplier must accrue materially faster: 59495448826830583661 <= 84484727158243929258] test_floatingMultiplierSetMidwayAlsoChangesNothing()
   ```
   Read line by line: no pranks beyond the deployer's own OWNER/BORROWER wiring, no mocks, no
   non-production values (band 1e27–2e27 matches `DeployInfra.sol:50`). Underwriter rate is zeroed,
   which isolates the liquidity leg fairly. No one-line change makes it pass without fixing the IRM.

3. **Tried to find a multiplier / cadence / underwriter-rate combination that moves it.**
   `audit/tests/scratch/verify/MED-MULTIPLIER-INERT/V_MultiplierInert.t.sol`:
   ```
   FOUNDRY_TEST=audit/tests/scratch/verify/MED-MULTIPLIER-INERT forge test --match-path 'audit/tests/scratch/verify/MED-MULTIPLIER-INERT/*' -vv
   [PASS] testFuzz_multiplierNeverMoves(uint256,uint8) (runs: 256)
     multiplier: 1000093230531342309502333752
     debt 1x  : 1349847622304407867048
     debt m x : 1349847622304407867048
   [PASS] test_midLifeChangeMatchesControl()
     debt raised to 2x mid-life: 1178664180751240921246
     debt control (1x)         : 1178664180751240921246
   [PASS] test_nothingElseReadsIt()
   ```
   The fuzz bounds `m` to `[irm.minimumMarketMultiplier(), irm.maximumMarketMultiplier()]`, sets a
   10% underwriter rate on both markets, and charges 1–12 times over a year; the assertion is a
   1e6-wei tolerance and every run came back exactly equal. The mid-life test compares against an
   untouched control market rather than against the market's own earlier window (the PoC's second
   test compares windows of a compounding index, which is a weaker comparison — see corrections).
   `healthiness`, `availableCredit`, `totalDebt` are identical across 1x and 2x, so nothing else in
   the floating path consumes the multiplier either.

4. **Reachability / roles.** `Registry.sol:327` puts `setMarketMultiplier` under the market OWNER
   role; `Registry.sol:370` grants the market `updateMarketMultiplier` on the IRM. Production
   `DeployInfra.sol:50` initialises the band as `(1e27, 2e27)`; `_marketMultiplier` is unset → 1x.
   So the state is reachable by the market owner alone, and the default deployment is unaffected
   until an owner raises it.

5. **Design intent.** `IInterestRateModel.sol:156-160,240` — "multiplier for a market's liquidity
   interest rate"; `IBaseMarket.sol:184` — "reindexes scaled debt so outstanding principal is
   unchanged" (i.e. principal fixed, rate meant to move); `FloatingMarket.setMarketMultiplier`
   comment — "changing it would otherwise reprice every outstanding loan". All three assume the
   multiplier does something going forward. `git log -S marketMultiplier` shows the index-side
   `rayMul(marketMultiplier)` and the fixed-side rate multiplication were introduced in the same
   commit (`144a5de Major refactor: Fixed Markets`), so the author intended parity. Not intended.

6. **Repo tests.** `test/integration/DebtLifecycle.t.sol:52-58` names an assertion "debt backed
   at the higher rate" but only checks `totalDebt == creditBackedSupply` after a 2x change — an
   invariant that holds trivially whether or not the rate moved. `Lender.t.sol:82-91` only checks
   the setter's band revert / success. `LendingFlow.t.sol:179-183` asserts principal/health are
   unchanged by the change (true, and consistent with inertness). No test in `test/` asserts the
   floating premium grows with the multiplier, so the suite passing is not evidence against D1.

7. **Existing mitigations / substitutes.** Per-market pricing does exist on the *underwriter* leg
   (`updateUnderwriterRate`, capped by `maximumUnderwriterRate`, paid to tranches); the multiplier
   was the only per-market lever on the *liquidity* leg (paid to stcUSD). Governance can still
   move the global slopes. So a riskier floating market can be priced up, just not for lenders
   specifically. This is why the harm is "promised return not delivered" rather than value at risk.

## Corrections to the finding text (bullet list, or "none")
- The mid-life PoC (`test_floatingMultiplierSetMidwayAlsoChangesNothing`) compares the market's
  second 100-day window to its first; those differ anyway because the index compounds. It still
  fails, but a cleaner proof is the control-market comparison in step 3, which is bit-identical.
- "to the wei" is accurate in every run observed, but the honest statement is "equal up to the
  half-up rounding of two `rayMul` operations"; the fuzz never saw a single-wei difference.
- "min/max multiplier band in the IRM is dead configuration for floating markets" — true; add
  that it is *live* for `FixedMarket`, so the band cannot simply be removed.
- Severity: Medium → Low under Immunefi ("fails to deliver promised returns, no value lost").
  Nothing is extractable, no actor benefits, production defaults to 1x, and the underwriter-rate
  lever still provides per-market risk pricing on the tranche leg. Keep as a design defect that
  must be fixed before any owner is told the multiplier prices floating credit.
- Recommendation is sound; note the simplest fix is a per-market `RateData` for the liquidity
  leg accrued at `liquidityRate.rayMul(multiplier)`, and that on upgrade every floating market's
  `lastLiquidityIndex` must be re-seeded from the new per-market index or the first charge after
  the upgrade will mis-accrue.

## Residual doubt (what would settle it if still uncertain)
None on the mechanics. The only open question is the severity label, which depends on the rubric:
if the protocol documents the multiplier to lenders as a risk-pricing guarantee for floating
markets (e.g. in public docs or a lender-facing UI showing "2x market"), a reviewer could argue
the silent under-delivery is a Medium griefing of lenders. Nothing in the repo makes that promise.
