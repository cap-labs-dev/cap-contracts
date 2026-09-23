# Accounting fuzz and invariant tests

See [execution results and findings](RESULTS.md) for the tested commit, timings,
operation counts, baseline skips and issue classification.

## Property specification (written before the assertions)

The suite covers protocol accounting, risk limits, vesting, vault issuance and
withdrawals. Unit and integration tests exercise arithmetic and lifecycle
boundaries alongside the stateful campaigns below.

The stateful fixture uses CapDeployer and Registry's real AccessManager selector
table, real markets, Oracle/ChainlinkAdapter, Vault, Stablecoin, Wrapper, Tranche,
Underwriter and IRM. Only ordinary ERC20 assets, external feeds and Aera custody
are mocked. No RPC is required. Actors receive finite budgets at deployment;
operations never mint assets to repair a failed precondition.

### Live-state properties

1. **Custody:** each ERC6909 supply equals the underlying tokens in Vault. This
   closed system permits no custody donations, rebases or transfer fees. For a
   deployment permitting donations the general requirement is supply <= custody.
   External token conservation also counts actor holdings and liquidation receipts.
2. **Debt:** sum of enumerated fixed loans equals aggregate fixed debt. Independent
   principal receipts, premium allocation events, repayments and write-offs explain
   credit issuance. Floating live debt minus the two *unrealized* premium components
   plus fixed debt equals creditBackedSupply, exactly. No invariant charges premium.
3. **Backing:** idle reserve + investments + realized credit equals supply minus
   recognized bad debt, in this 18-decimal reserve campaign. Investments have no
   unreported yield/loss; credit write-offs, cover burns and exit loss absorption
   are explicit. Collateral is security for debt and is not counted a second time
   as a reserve asset.
4. **Queues:** a ghost receipt ledger records requests, control transfers and burns.
   Remaining receipt shares equal pending + claimable per receipt and sum to the
   redemption queue. Escrow equals the queue except on cUSD, whose same address
   also holds the premium pot. Pool queued positions reconcile per receipt.
5. **Exits:** balance deltas equal returned asset payments; exact-asset calls pay
   exactly their input. Ceil share quotes must bracket the required rational asset
   value. A successful exit consumes no more than current liquidity. A withdrawal
   alone preserves health if the market was healthy immediately before it;
   prices, rates, time and risk parameters are held fixed across that call.
6. **Pool marks:** totalAssets = idle ERC6909 + cached position books. A book is
   compared with an independent rational position valuation only when a documented
   marking operation occurs. Unrealized losses may remain between reports. Queued
   and wallet shares are valued together. The known stale-book exit trade-off is
   not reported as a new defect.
7. **Premium:** Fund and Claimed events build separate funded/actually-paid ledgers
   checked against token custody (less cUSD queue escrow). Stored remainder is
   remaining + vested; allocated is funded minus stored remainder. Unwritten
   vesting is kept separate. Retained rounding and cleared short payments are
   measured in the dedicated checkpoint tests, not confused with spendable cash.
   Entitlements need not all be payable: short-payment capping is accepted.
8. **Round trips:** in explicitly debt-free, price-constant, premium-free cases,
   final realizable assets cannot exceed contributed assets plus tracked donations.
   Seed shares remain owned by the dead-share holder. A closed-system unwind
   separately repays debt using pre-funded actors, recalls the mock integration,
   drains requests and deallocates positions; it is not a live-state invariant.
9. **Retirement and limits:** `Killed` events latch permanently and retired vaults
   advertise zero deposit/mint capacity. A tranche below 1% of par is retired;
   a depleted Underwriter closes deposits even before a later report latches it.
   The Underwriter's unlocked share quote never pays more than its idle cash.
   Each successful write-off leaves no immediately available borrowing capacity.
10. **Vesting configuration:** changing a period first checkpoints the old schedule.
    Existing claimable earnings and the unvested pot are preserved at that instant.

All conservation assertions use zero tolerance. Where an integer rational bound
is needed, floor/ceil are proved with multiplication inequalities, rather than a
percentage tolerance. Any explicit dust allowance must be stated in raw units.
Health after adverse price/risk changes is deliberately not an invariant.

## Campaign structure

Expected authorization failures belong to a separate selector/test and use
specific errors. Unexpected reverts fail the run.
Counters partition each selector's attempts into successes, skips and expected
reverts; they do not interpret a skipped handler as protocol coverage.

- `handlers/ProtocolHandler.sol`: 27 explicitly selected operations, three LPs,
  a separately permissioned borrower and liquidator, two real markets, four
  tranches and a two-position Underwriter. Market rates are explicitly nonzero.
- `Protocol.invariant.t.sol`: a healthy-debt campaign and a loss campaign. The
  latter starts after checked write-off/liquidation, a partial claim, paid premium
  and queued deallocation. Bootstrap calls are excluded from random-call metrics.
  Both campaigns check all live properties after every call and unwind after
  every sequence. One combined invariant keeps these properties on the same state.
- `NumericalBoundaries.t.sol`: custody and reserve decimal scaling, zero/one/seed
  boundaries, donations, multiple receipts, exact-asset withdrawals, credit-limit
  exits, liquidation granularity, maturity/grace neighbors, rate kink neighbors,
  and an exhaustive small-integer reference for nonlinear shortfall exit quotes.
- `PremiumCheckpoint.t.sol`: explicitly labeled allocation/full-vesting checkpoints
  account for funded, unvested, allocated, paid, capped and retained amounts;
  wrapper round trips separately account for donations and permanent seed shares.

Ghost ledgers use action inputs, cash deltas and protocol flow events; they do not
read private accounting slots. Receipt events and premium flow events are checked
against actual custody. Events and getters can share a bug, so independent cash
conservation and integer reference checks are also necessary. The ghost pool mark
uses the ERC4626 rational ownership model (including its virtual unit); it is not
an independent model of every possible pool valuation policy.

## Exact commands

From the repository root, install the checked-in dependencies and pinned toolchain:

```sh
git submodule update --init --recursive
npm install --global yarn@1.22.22
yarn install --frozen-lockfile --ignore-scripts
foundryup --install v1.5.1
forge --version
```

Compiler: Solidity **0.8.36**, Osaka EVM, existing optimizer settings, no added
via-IR requirement. The tested Forge build is `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`.

```sh
# Local suite: 256 fuzz runs; 32 invariant runs, depth 64, per campaign
bash script/run-fuzz-tests.sh local

# Full PR suite: 1,000 fuzz runs; 256 invariant runs, depth 128, per campaign
FOUNDRY_FUZZ_SEED=0xcafef00d bash script/run-fuzz-tests.sh pr

# Full deep suite: 10,000 fuzz runs; 2,048 invariant runs, depth 256, per campaign
FOUNDRY_FUZZ_SEED=0xd33f bash script/run-fuzz-tests.sh deep

# Run only the new tests, or one deterministic lifecycle
bash script/run-fuzz-tests.sh local --match-path 'test/invariant/*'
forge test --match-test test_checkedLifecycleReachesLossPartialClaimAndUnwind -vvvv

# Check existing tests separately to distinguish baseline regressions
forge test --no-match-path 'test/invariant/*'

# Inspect resolved budgets; --offline can be added once solc is installed
FOUNDRY_PROFILE=pr forge config --json
forge fmt --check test/invariant
```

`default` remains the repository's existing profile. Use `local` explicitly for
short iteration. Existing test-specific `forge-config` annotations can override
their named profiles; the new tests contain no budget overrides. Random seeds are
generated by the runner when none is supplied and recorded *before* execution.

### Artifacts and reproduction

The runner writes `artifacts/fuzz-and-invariant-tests/<profile>/run.txt`, `sources.sha256`,
`forge.log` and `metrics.json`. Per-sequence logs are in
`artifacts/fuzz-and-invariant-tests/{healthy,loss}-metrics.jsonl`. They record a calldata hash,
seed, profile and `[attempted, succeeded, skipped, expected_reverts]` per selector.
The summarizer uses the repository's existing Node.js runtime with no additional
packages. It removes duplicate final sequence replays and bootstrap calls:

```sh
node script/summarize-invariant-metrics.js --profile deep --seed 0xd33f
```

Metrics are appended, so separate seeds remain distinguishable. For reproduction,
use the recorded seed, profile, matching source hashes and toolchain. Foundry
automatically replays minimized failures retained under `cache/invariant` and
`cache/fuzz`. Preserve those directories; do not delete counterexamples to get a
green run. `forge test --rerun -vvvv` reruns previous failed tests. Copy the exact
minimized sequence into a deterministic regression when a failure is confirmed.
The runner propagates a nonzero test exit; no `continue-on-error`, broad revert
catch, test exclusion or expected-failure naming hides a confirmed defect.

The PR/scheduled/manual workflow uploads logs, seeds, metrics and both failure
directories even on failure, for 30 days. Weekly and manual deep runs use the
same pinned version. GitHub execution itself is not claimed as locally verified.

### What belongs in Git

Commit the test sources, handler, runner and summarizer, Foundry profiles, CI
workflows, assumptions and concise validation results. The existing `.gitignore`
excludes `artifacts/`, `cache/`, `out/` and `*.log`, including the generated reports
and local replay caches. No additional blanket JSON or JSONL ignore is needed.

Keep failure caches locally and preserve them as CI artifacts. When a failure
reveals a confirmed defect, add a deterministic `.t.sol` regression under
`test/invariant/` so it survives a clean checkout. A deliberately curated fixture
can also live under `test/invariant/`; generated cache files should stay ignored.

When editing handlers, use multiline blocks for guards containing multiple
statements. With the pinned formatter and this repository's `preserve` setting,
compact multi-statement guards were observed to lose their braces. Inspect the
formatter diff and run tests after formatting.

## Scope and limitations

- All assertions observe the state before any optional maintenance. `charge`,
  `report`, `recall`, `cover` and `unwind` are separately named operations.
- The stateful reserve and collateral are 18 decimals. The dedicated numerical
  fuzz tests deploy 6-, 8- and 18-decimal reserves/collateral/custody assets. They
  do not constitute a mixed-decimal stateful market campaign.
- Stateful deposits/draws use finite budgets and at most 1,000 tokens per call;
  fuzz boundaries separately reach `1e24` reserve/deposit units and `1e27` custody
  units. This is not a claim of correctness throughout the uint256 domain.
- Time advances up to seven days per call and is capped at five years. Feeds use
  CapDeployer's documented ten-year staleness window. Price shocks range from
  $0.01 to $2.00. Oracle outages and malformed external tokens remain covered by
  existing tests, not these valid-operation campaigns.
- Tiny indexed borrow/repay requests below `1e9` cUSD wei are skipped in random
  debt handlers to avoid intentionally unrepresentable scaled amounts. Existing
  `AccountingIntegrity.t.sol` tests cover one-wei indexed-debt residues and their
  specific rejection. Liquidation granularity is separately fuzzed down to one wei.
- Some executable-operation handlers bound amounts by liquidity/claimability
  views. Independent capital calculations, rational ceil checks, actual payments,
  and boundary tests cross-check those views; not every max view is proven maximal.
- Underwriter cached marks can lag losses by design. Do not apply an individual
  fair-NAV round-trip invariant to those stale marks. Pool book and queued-position
  conservation are checked at their specified checkpoints. The integration tests
  separately exercise live default-tranche issuance pricing and reject re-entry
  into retired pools and tranches.
- The reserve integration models deposits and recalls without yield or hidden
  impairment. Reserve loss recognition is tested in a separate small-integer
  scenario with an actual mock-token loss. Live Aera strategy behavior is excluded.
- The end hook repays using the borrower's **initial** reserve-funded budget,
  recalls the reserve mock and deallocates pools. It proves collateral queues drain
  in that funded scenario. It does not assert every cUSD holder can immediately
  exit recognized bad debt, or prove liveness when a borrower refuses to repay.
- Risk mutation covers LT; vesting mutation covers all six reward-bearing vaults;
  role mutation covers depositor grants/revocations.
  Full governance timelocks, delayed grants, beacon upgrades, changing tranche
  membership, fixed `borrowMore`, and arbitrary rate reconfiguration remain in
  existing unit/integration coverage rather than the stateful selector set.
- Actual premium payout capping is accepted; entitlements are not asserted to
  fit the pot. Zero-earning-supply views, fixed split-borrow pricing and stale pool
  marks are previously known topics and are not new findings here.

Foundry profile/targeting references: [configuration](https://www.getfoundry.sh/config/index.html)
and [invariant test hooks](https://foundry-rs.github.io/foundry/foundry_evm/executors/invariant/IInvariantTest/index.html).
