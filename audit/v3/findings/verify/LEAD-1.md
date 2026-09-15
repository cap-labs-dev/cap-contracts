# LEAD-1 — owner appends a junior in another priced asset and exits the senior while debt is out

**Verdict:** CONFIRMED-AT-LOWER-SEVERITY — **Low** (design/governance gap; not a coverage defect). Mechanically reproducible exactly as written; the "expected" property the proof asserts is the inverse of a property the repo's own suite asserts and the natspec documents, and the premise "GOVERNOR sized the line against WETH" is not a contract-level fact on HEAD.

## What I checked (HEAD a843c1d, OZ 5.7.0 verified in node_modules)

Read end to end: `Registry.createTranche`/`_deployTranche` (L177-199, L318-341), `BaseMarket.lockedValue` (L270-289), `creditLimit`/`variableCreditLimit` (L307-322), `_setTranches` (L390-406), `Tranche.unlockedSupply`/`totalCapital` (L175-198), `Oracle.setSource` (GOVERNOR-only per `_configureInfraRoles`), `IBaseMarket.lockedValue` natspec ("Juniors lock first"), `IRegistry.createTranche` natspec ("Add a junior tranche to a market and reweight the waterfall. Caller must hold the market owner role").

Author's PoC re-run: `P14_Whitelisted::test_P14_ownerSwapsCollateralBasisAfterSizing` PASS (behaviour present); `Expected_P14::test_EXPECTED_seniorStaysLockedWhenOwnerAppendsJunior` FAIL `[senior collateral must stay locked: 1000000000000000000000000 >= 1000000000000000000000000]`. Reproduces.

## Strongest attack on the finding, in the brief's order

**(1) Precondition that cannot hold on HEAD — the line was never "sized against WETH".** `setFixedCreditLimit` stores a bare notional (`BaseMarket.sol:L100-104`). Nothing in storage binds it to an asset, a tranche, or a capital snapshot. The asset set of a market is chosen at creation by the WHITELISTED creator (`_createMarket`, `_assets` caller-supplied), not by GOVERNOR, and the protocol has no per-asset risk parameter anywhere: one `lt`/`buffer`/`ltv` per market applies to every asset any of its tranches holds. So the same "swap" is reachable without `createTranche` at all:

- `test_verify_sameSwapWithoutCreateTranche_preexistingEmptyJunior`: market created as `[WETH, ALT]` with the ALT junior empty; GOVERNOR sizes while seeing `[WETH: 1M, ALT: 0]`; eve borrows, funds ALT, exits all WETH. Identical end state.
- `test_verify_singleTrancheRotationWithinTheSameAsset`: single-tranche WETH market; a second depositor adds 1M WETH to the same tranche; eve's 1M is fully redeemable. "Underwriter rotation" is native to the lock model, tranche-append or not.

The increment `createTranche` adds is only: *post-sizing*, the set of assets can grow to any asset GOVERNOR has a feed for. That is real, but it is one step on a path GOVERNOR already could not close by sizing.

**(2) Existing check elsewhere — GOVERNOR's feed whitelist bounds the substitute set, and there is an event.** `_deployTranche` reverts `PriceError` for an unpriced asset; `Oracle.setSource` is GOVERNOR-only; delisting a feed closes the door for future appends (`test_verify_unpricedAssetCannotBeAppended_andCreateTrancheEmitsAsset`). The finding's "no event that says so" is wrong: `Registry.CreateTranche(market, tranche, asset, ownerRole, depositorRole)` and `BaseMarket.SetTranche(tranche, weight, index)` both fire (same test, `expectEmit`). Asked question (b): yes — "any priced asset" is exactly the GOVERNOR-approved feed set, which weakens "an asset GOVERNOR did not evaluate" to "an asset GOVERNOR priced but did not approve *for this market*".

**(3) Numbers — re-derived; one small correction, and (d) is answered yes.** Required lock is `ceil(500,000e18 / 0.7) = 714,285.714285714285714286e18` (author rounds to "714k"; fine). At the instant of the swap the USD coverage requirement is preserved, not weakened:
- `test_verify_swapPreservesUsdCoverageRequirement`: `lockedValue(senior)` goes 714,285.71 → 0 only because `lockedValue(junior)` becomes 714,285.71; after eve's exit `totalCapital = 1,000,000e18 + 1000` (dead shares), health `1.6e27` (not merely ≥ 1), `creditLimit = 500,000e18` (line exactly full; `variableCreditLimit = 1M × 0.7`).
- `test_verify_underfundedJuniorLeavesSeniorLockedByTheShortfall`: 700k ALT at $1 leaves `lockedValue(senior) = 14,285.714285714285714286e18`, senior locked shares `14285714285714285714286`; after max exit capital ≥ requirement.
- `test_verify_cheapSubstituteIsValuedAtOraclePrice`: 1M ALT at $0.50 leaves the senior locked by $214,285.71.
So the substitute must be at least `D/(lt−buffer)` of oracle USD before one wei of the senior beyond that can leave. cUSD holders' coverage ratio (1/(lt−buffer) = 1.43× at oracle) is unchanged at the swap. What changes is *which* asset's price/liquidity/feed risk they hold — and the protocol expresses no preference between two GOVERNOR-priced assets.

**(c) `_setTranches` health check:** inert for this path — an empty append is health- and lock-neutral (`test_verify_setTranchesHealthCheckIsInertForAnEmptyAppend`). The real guard is `lockedValue`, which does its job in USD. It is not a guard on asset identity because the design has none.

**(4) Severity.** The Expected test asserts "senior collateral must stay locked" when a funded junior covers the requirement. The repo's own `test/integration/LockedValue.t.sol::test_seniorUnlockedAmountIsPricedInTokens` asserts the opposite (`"junior alone covers it, senior is free"`, `senior.unlockedSupply() == totalSupply()`, PASS on HEAD), and `test/integration/Tranche.t.sol::test_createTranche_addsAJuniorLayerWithItsOwnAsset` asserts the new layer "does not have to hold what the existing ones hold". A proof that fails only because it contradicts a documented, tested design choice is not a failing-test proof of a defect under `_SCHEMA.md`. Net profit to eve at the swap: zero — she posts ≥ $714k of ALT (at oracle) to retrieve $1M of WETH; her USD position is unchanged and she now holds ALT price risk on the locked portion. No depositor loses money while the system reports itself covered; it *is* covered at oracle prices. Loss needs a second, independent event (ALT drawdown > 30% before liquidation, or a bad ALT feed), which is the generic collateral-risk the protocol accepts for every priced asset. WS-C rated the identical mechanism Informational (C-9) with the same numbers. Under the stance that owners are third parties, the residual is: GOVERNOR's per-market notional cannot be conditioned on collateral composition, before or after sizing. That is a governance-process/design gap — Low.

**(5) Existing coverage:** the mechanism itself is covered (LockedValue.t.sol, Tranche.t.sol above); the *post-sizing asset-introduction* composition is not, which is what the author's demonstration adds.

## Independent test

`audit/v3/tests/scratch/verify/LEAD-1/LEAD1_Verify.t.sol` — run `FOUNDRY_TEST=audit/v3/tests/scratch/verify/LEAD-1 forge test --match-path 'audit/v3/tests/scratch/verify/LEAD-1/*' -vv`:

```
Ran 7 tests for audit/v3/tests/scratch/verify/LEAD-1/LEAD1_Verify.t.sol:LEAD1_Verify
[PASS] test_verify_cheapSubstituteIsValuedAtOraclePrice() (gas: 4515776)
[PASS] test_verify_sameSwapWithoutCreateTranche_preexistingEmptyJunior() (gas: 4483573)
[PASS] test_verify_setTranchesHealthCheckIsInertForAnEmptyAppend() (gas: 4085117)
[PASS] test_verify_singleTrancheRotationWithinTheSameAsset() (gas: 2796852)
[PASS] test_verify_swapPreservesUsdCoverageRequirement() (gas: 4574621)
Logs:
  capital after swap (USD): 1000000000000000000001000
  required (USD)          : 714285714285714285714286
  health after swap (ray) : 1600000000000000000001600000
  creditLimit after swap : 500000000000000000000000
[PASS] test_verify_underfundedJuniorLeavesSeniorLockedByTheShortfall() (gas: 4552681)
Logs:
  senior locked shares: 14285714285714285714286
[PASS] test_verify_unpricedAssetCannotBeAppended_andCreateTrancheEmitsAsset() (gas: 4587233)
Suite result: ok. 7 passed; 0 failed; 0 skipped
```

## Recommendation to the lead

**Demote to Low and re-word; merge with C-9.** Keep the demonstration (it is the only test in the tree showing post-sizing asset introduction), drop the `Expected` test as "proof" (it asserts against `test_seniorUnlockedAmountIsPricedInTokens`), and drop the claims "no event that says so" and "sized against WETH". Re-word the defect as: *credit sizing is a per-market USD notional with no binding to collateral composition; the asset set of an indebted market is an owner decision bounded only by the global oracle feed whitelist, and can change after GOVERNOR sizes the line (`createTranche`) or without it (funding a pre-existing tranche).* State explicitly that USD coverage `≥ D/(lt−buffer)` at oracle is preserved throughout, so the exposure is asset-substitution risk between two GOVERNOR-priced assets, not under-collateralisation. Recommendation stands and is the right one if asset-specific sizing is intended: a GOVERNOR-maintained per-market asset allowlist checked in `_createMarket`/`_deployTranche`, or per-asset credit caps; cheaper alternative from C-9, require `weights[new] == 0` or a GOVERNOR co-sign when `totalDebt() > 0`. If the team confirms "any priced asset at the market's lt" is the intended collateral policy, this is Informational.
