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
**Invariant broken:** the invariant ID from audit/00-plan.md, if applicable

## Also report
At the end of your file, a `## Invariants` section listing any invariant from audit/00-plan.md
you believe you broke, and any NEW invariant the code implies that the plan missed.

## Rules of engagement
- DO NOT modify `contracts/` or the existing `test/` tree. Ever.
- You MAY write scratch Foundry tests under `audit/tests/scratch/<WS>/` to check a hypothesis.
  `test/shared/CapDeployer.sol` gives you a full protocol deployment - use it.
- Run tests with: `FOUNDRY_TEST=audit/tests forge test --match-path 'audit/tests/scratch/<WS>/*' -vv` (the env var is REQUIRED - foundry.toml points test= at test/, do not edit foundry.toml)
- Environment is pinned to OpenZeppelin 5.7.0 (verified byte-identical to the registry).
