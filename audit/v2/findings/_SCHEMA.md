# Finding schema and ground rules (read before writing anything)

## Ground rules
- **Assume nothing.** This codebase is unusually comment-heavy and many comments assert
  "safe because X". Every such claim is a HYPOTHESIS TO TEST, not evidence. Where a comment
  claims safety, your job is to try to break it and say whether the claim survived.
- **No speculative findings.** Medium or above requires EITHER a concrete ordered exploit path
  with the attacker's starting capital and net profit, OR a failing test. If you cannot produce
  one, demote to Informational and say explicitly why it could not be demonstrated.
- **No finding inflation.** A short report of real bugs beats a long one padded with style
  notes. Gas/style go in a separate `## Appendix: gas & style` section, unranked, no severity.
- **Read the implementation end to end at least once.** Do not audit from names, tests or docs.
- Severity = impact x likelihood (Immunefi-style): Critical / High / Medium / Low / Informational.
  State likelihood as preconditions + cost to the attacker, never as a vibe. Give dollars at
  risk where estimable; say so when it is not.

## Every finding uses exactly this structure

### [SEVERITY] Title - one line, states the defect
**Location:** path/to/File.sol:L120-L145 (function name)
**Impact:** what breaks, who loses, how much
**Likelihood:** what must be true; who can cause it; what it costs them
**Exploit path:** numbered steps, with starting state, attacker capital, and net outcome
**Proof:** test file/name that fails on current code, or model output with the threshold
**Recommendation:** the specific fix, and any second-order effect of that fix
**Invariant broken:** the invariant ID from audit/v2/00-plan.md, if applicable

## Also report
At the end of your file, a `## Invariants` section listing any invariant from audit/v2/00-plan.md
you believe you broke, and any NEW invariant the code implies that the plan missed.

## Rules of engagement
- DO NOT modify `contracts/` or the existing `test/` tree. Ever.
- You MAY write scratch Foundry tests under `audit/v2/tests/scratch/<WS>/` to check a hypothesis.
  `test/shared/CapDeployer.sol` gives you a full protocol deployment - use it.
- Run tests with: `FOUNDRY_TEST=audit/v2/tests forge test --match-path 'audit/v2/tests/scratch/<WS>/*' -vv` (the env var is REQUIRED - foundry.toml points test= at test/, do not edit foundry.toml)
- Environment is pinned to OpenZeppelin 5.7.0 (verified byte-identical to the registry).

## Round 2 specifics
- This is a RE-AUDIT of commit `3dad5ef` ("Refactor premium vesting and natspec"). The round-1 report is
  `audit/cap-v2-audit-report.md`; round-1 findings/PoCs are under `audit/findings/` and `audit/tests/`
  (the latter no longer compile against the new API — port, do not run in place).
- **Fuzz testing is a first-class deliverable this round.** Every workstream must ship at least one
  stateful (handler-based `StdInvariant`) or property fuzz suite for its area under
  `audit/v2/tests/scratch/<WS>/`, run it, and paste real run/call counts. Name invariant files
  `*.invariants.t.sol`. Default profile is fine for development; state what you ran.
- Test deployer: `test/shared/CapDeployer.sol` (now deploys the REAL `Oracle` + `ChainlinkAdapter`
  with an 8-dec `MockAggregator` per asset; `_setPrice(asset, price18)`; depositors must `optIn()`
  to earn premium — `_fundTranche`/`_fundUnderwriter` do it for you). Role ids changed:
  `MARKET = 4`, `REGISTRY = 5`, `LIQUIDATOR = 6` (no MINTER). Registry entry points:
  `createFloatingMarket`, `createFixedMarket`, `createUnderwriter`, `createTranche` (market OWNER).
- Run: `FOUNDRY_TEST=audit/v2/tests forge test --match-path 'audit/v2/tests/scratch/<WS>/*' -vv`
  (scope with `FOUNDRY_TEST=audit/v2/tests/scratch/<WS>` if another workstream's WIP breaks the build).
