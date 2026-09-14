# Cap v2 audit tests, round 3 (HEAD `a843c1d`, branch `cap-network`)

Audit tests live outside `test/` on purpose. `foundry.toml` keeps `test = "test"` untouched;
point Foundry at the audit tree with `FOUNDRY_TEST`. Always point it at the **narrowest**
directory you need: other workstreams keep half-finished files under `audit/v3/tests/scratch/*`
and a wide `FOUNDRY_TEST=audit/v3/tests` compiles (and fails on) all of them.

## Layout

| Path | What |
| --- | --- |
| `shared/CapDeployer6.sol` | `test/shared/CapDeployer.sol` world with a **6-decimal** stablecoin underlying (USDC shape) and 18-dec collateral. Subclasses the stock deployer; only the core-contract step is repeated. `_deployCap6()` / `_deployCap6WithConfig()`. The stock 18-dec `_deployCap()` stays available on the same contract. |
| `invariants/CapHandler.sol` | Stateful fuzz handler: every user/privileged entry point (stablecoin, 4 tranches, 1 underwriter, floating + fixed markets, guardian `setLt`, governor `setLiquidationBonus`). Every world call is try/catch'd and counted in `ghost_reverts`, so the suite runs under `fail_on_revert = true`. |
| `invariants/Cap.invariants.t.sol` | Invariants I1-I19 (round 2, ported to the ERC-7540 receipt queue) plus I30, I33, I34, I35, I37, I38. |
| `invariants/HandlerProbe.t.sol` | Deterministic smoke test: scripted path through the handler (borrow full line, price halves, write-off, liquidation, queues, underwriter) printing the ghosts and running the invariant bodies in that regime. |

## Run

```sh
# compile only the invariant suite
FOUNDRY_TEST=audit/v3/tests/invariants forge build

# quick campaign
FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=25 \
FOUNDRY_TEST=audit/v3/tests/invariants \
forge test --match-path 'audit/v3/tests/invariants/Cap.invariants.t.sol' -vv

# deep campaign (the one reported)
FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=50 \
FOUNDRY_TEST=audit/v3/tests/invariants \
forge test --match-path 'audit/v3/tests/invariants/Cap.invariants.t.sol' -vv

# smoke probe (prints ghosts)
FOUNDRY_TEST=audit/v3/tests/invariants \
forge test --match-path 'audit/v3/tests/invariants/HandlerProbe.t.sol' -vv

# reproduce a failing sequence
... --fuzz-seed <seed printed at the end of the failing run>
```

`FOUNDRY_DISABLE_NIGHTLY_WARNING=1` silences the nightly banner. A `forge build` from another
process can hold the artifact lock; forge waits, just let it.

## Invariant notes

* **I1** is restated in units: `balanceOf` is 6-dec base units and `unlockedSupply` is 18-dec
  shares, so the round-2 direct comparison only worked at 18/18. Now
  `convertToAssets(unlockedSupply()) <= balanceOf(stablecoin)`.
* **I13** `balanceOf(self) == redemptionQueue()` on tranches/underwriter; `>=` on the stablecoin
  (its premium pot sits in the same balance).
* **I15** is kept verbatim from round 2 (strict FIFO). `ERC7540AsyncRedeem.claimableRedeemRequest`
  documents that already-claimable shares may settle out of order; read a failure against that.
* **I17** restated for the watermark queue: per-request `claimable <= unlockedSupply`, and the sum
  of live request shares (`pending + claimable` for `controllerOf(id)`) `== redemptionQueue()`
  (= `redeemQueue - settledQueue`). `requestShares[id]` itself is not public.
* **I30** calls `floating.chargePremium()` in the body (the fixed market charges eagerly), then
  asserts `sum(totalDebt) == creditBackedSupply` within +-2 wei (one per market). Coverage
  `sum(totalCapital * lt) / sum(debt)` is recorded in `ghost_i30_minCoverageRay`, not asserted.
* **I33** `controllerRequests` is a private `EnumerableSet` with no getter, but `maxRedeem(c)`
  walks it, so the set is checked against the per-request views:
  `min(unlocked, sum_{controllerOf(id)==c} claimable(id, c)) == maxRedeem(c)`.
* **I38** `lt * (1 + liquidationBonus) <= 1` per market. `setLt` (guardian, `(buffer, 1e27]`) and
  `setLiquidationBonus` (governor, `[0, 0.1e27]`) are handler actions over their full permitted
  ranges, so the fuzzer explores the combination. A failure is a finding, not a harness bug.
* Handler bounds are modular (`lo + x % (hi - lo + 1)`); when scripting the handler by hand
  (see `HandlerProbe`), pick arguments that fold onto the value you want.

## Result of the reported campaign (runs=64, depth=50, `invariants/deep-run.log`)

22 / 23 pass at 3200 calls each, 0 uncaught reverts (expected reverts are swallowed in the handler
and counted in `CapHandler.ghost_reverts`). One failure, kept deliberately:

```
[FAIL: I38 fixed: lt * (1 + liquidationBonus) > 1, liquidation over-releases collateral:
       1009977059473562492737962699 > 1000000000000000000000000000]
  [Sequence] (original: 7, shrunk: 1)
    CapHandler.setLt(3917629213437395, 7562618360694350876715657871558336)
    -> guardian FixedMarket.setLt(~0.99017e27) with the default liquidationBonus = 0.02e27
Fuzz seed: 0x134551bc4ad5b41e1881b40826195512de0e82d6bdafeb608aeeac3a89f2622f
```

`BaseMarket.setLt` accepts any `lt` in `(buffer, 1e27]` and `InterestRateModel.setLiquidationBonus`
any bonus in `[0, 0.1e27]`, with no cross-check. Once `lt * (1 + bonus) > 1`, `_liquidate`
releases `repaid * (1 + bonus)` of collateral value for debt that was only `lt`-covered, so a
liquidation at the threshold hands out more collateral than the debt it clears is backed by.
`HandlerProbe` states the same violation deterministically (lt 0.96, bonus 0.10 -> 1.056).

## Deep-run logs (lead)

| Log | Config | Result |
| --- | --- | --- |
| `invariants/deep-run-64x50.log` | 64 × 50, harness author's run | 22/23 pass; I38 fails (`setLt(0.99e27)` at bonus 0.02) |
| `invariants/deep-run-1000x200.log` (= `deep-run.log`) | 1000 × 200, seed `0x5ca1ab1e…cab3`, 859 s | 21/23 pass, 200,000 calls each; I38 fails (known, D-2); I37 fails by exactly 1 wei after 7 calls (rounding gift) |
| `invariants/deep-run-I37-500x200.log` | I37 alone, 500 × 200, same seed, after restating with `ghost_shareOps` tolerance | PASS, 100,000 calls |

Killing tests for mutation survivors: `FOUNDRY_TEST=audit/v3/tests/mutants forge test --match-path 'audit/v3/tests/mutants/*'` (see `mutants/README.md`).
Verification tests: `FOUNDRY_TEST=audit/v3/tests/scratch/verify/<ID> forge test --match-path 'audit/v3/tests/scratch/verify/<ID>/*'`.
