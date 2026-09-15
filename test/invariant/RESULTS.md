# Execution and findings

Validation recorded on 2026-09-15. These results describe the initial suite on the
production baseline below; rerun the campaigns after subsequent changes.

## Baseline

- Production commit: `05b6aa76fd5b14855e02719361ad3334c23b22c2` (`cap-network`).
- Production contracts and shared deployment helpers were unchanged by this suite.
- Foundry v1.5.1, build `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`;
  solc 0.8.36; Darwin arm64.
- `forge test --offline`: **630 passed, 0 failed, 2 skipped**, 42 suites,
  4.31 seconds reported by Forge with cached compilation.
- Both skips are existing migration setup skips because `ETH_RPC_URL` is unset.
  Core tests require no private RPC.

## Final PR validation

Command:

```sh
FOUNDRY_FUZZ_SEED=0xcafef00d bash script/run-fuzz-tests.sh pr --offline
```

- **645 passed, 0 failed, 2 skipped**, 46 suites; **54.31 seconds wall time**.
- All ten new fuzz functions ran 1,000 cases (plus replay of an earlier harness
  counterexample where retained by Foundry).
- Each of the two invariant campaigns ran 256 sequences at depth 128:
  **65,536 randomized calls**, zero unexpected reverts.
- The healthy campaign recorded 22,817 successful operations, 8,709 skips and
  1,242 specifically expected authorization reverts.
- The loss campaign recorded 22,806 successful operations, 8,720 skips and
  1,242 specifically expected authorization reverts.
- Random operations, excluding bootstrap: healthy/loss campaigns respectively
  completed 695/564 borrows, 642/605 repayments, 12/95 liquidations, 22/104
  write-offs, 265/345 queued pool finalizations and 597/533 exact-asset settlements.
- All 512 unique sequences completed their explicit unwind and final accounting
  checks. Metrics exclude bootstrap and the final replay. Successful settlements
  are not all partial; the separate deterministic bootstrap asserts a partial
  settlement and a positive premium claim explicitly.
- PR timing includes contention with the concurrent deep run; it is a local
  measurement, not a GitHub runner performance guarantee. Budgets were not reduced.

Artifacts: `artifacts/fuzz-and-invariant-tests/pr/{run.txt,sources.sha256,forge.log,metrics.json}`.

## Deep validation

Command:

```sh
FOUNDRY_FUZZ_SEED=0xd33f bash script/run-fuzz-tests.sh deep --offline
```

- The completed Forge run: **645 passed, 0 failed, 2 skipped**, 46 suites;
  **1,016.77 seconds wall time** (16 minutes 57 seconds, including compilation).
- All ten new fuzz functions completed 10,000 cases, plus retained replay inputs.
- Both campaigns completed 2,048 sequences of depth 256: **1,048,576 randomized
  calls**, zero unexpected reverts, and 4,096 unique successful unwind checks.
- Healthy campaign: 366,845 successful operations, 137,178 skips and 20,265
  expected authorization reverts.
- Loss campaign: 363,985 successful operations, 140,038 skips and 20,265
  expected authorization reverts.
- Excluding bootstrap, healthy/loss campaigns completed respectively 275/929
  liquidations, 343/1,031 write-offs, 658/2,668 bad-debt covers, 4,759/5,794 queued
  pool finalizations and 9,313/8,663 exact-asset settlements.
- No budget was reduced. The 90-minute CI timeout leaves room for slower runners.

Execution caveat: a live runner edit started an unintended second deep run after
the first completed successfully. The duplicate was interrupted and archived
separately; the numbers above describe the complete first run only. No failing
protocol case was removed. The corrected runner parses its complete function
before execution and passed the local verification below.

## Final local runner verification

```sh
FOUNDRY_FUZZ_SEED=0x52454e414d45 bash script/run-fuzz-tests.sh local --offline
```

**645 passed, 0 failed, 2 skipped**, **9.87 seconds wall time**. Both local campaigns
completed 32 sequences at depth 64 (4,096 randomized calls total). This run verifies
the final runner, renamed artifact paths, source hashes and metrics pipeline.
Test properties, campaign budgets and compiler configuration are unchanged from
the completed PR/deep runs.
Final metadata and hashes are under `artifacts/fuzz-and-invariant-tests/local/`.

The JavaScript summarizer produced byte-for-byte identical reports to its previous
implementation for the recorded PR and deep campaigns.

Other checks: scoped `forge fmt --check`, `git diff --check`, Bash syntax, JavaScript
syntax, YAML parsing, and source-hash verification passed. CI configuration is
implemented; an actual GitHub Actions run was not triggered from this session.

## Findings classification

### Confirmed new implementation defects

None reproduced in the completed local, PR or deep campaigns and deterministic tests.
This is finite test evidence, not a claim that the contracts are defect-free.
No production changes are proposed merely to satisfy the tests.

### Harness corrections

Development failures included missing rate initialization, prank ordering and
vesting-time setup, plus compile/formatting issues. These were corrected before
the reported validation, without changing production contracts or weakening
assertions. Earlier failing fuzz inputs remained replayable and passed after
correction. The runner correction is described above.

### Specification assumptions and coverage questions

The [README](README.md) specifies reserve valuation, supported token behavior,
stale pool marks, funded unwind assumptions and numerical limits. Production
onboarding still needs to enforce non-rebasing/non-fee tokens and account for real
reserve strategy yield/loss. Those integrations are not proven by a custody mock.
The suite does not resolve the previously investigated zero-earning-supply views.

### Accepted or previously documented design behavior

- Permissioned borrowers and fixed split-borrow pricing remain as specified.
- Premium short-payment capping is measured; it is not reported as a new defect.
- Underwriter report lag is the documented cached-book model and already has a
  deterministic example in `test/integration/AuditSecurity.t.sol`.
- Fully wiped collateral recovery is not prioritized. Recognized bad debt can
  prevent an immediate full cUSD exit; the unwind does not manufacture backing.

Existing accounting regressions remain included, with no exclusions or weakened
assertions. Any future genuine campaign failure should remain failing and gain a
minimal deterministic regression before a production fix is considered.
