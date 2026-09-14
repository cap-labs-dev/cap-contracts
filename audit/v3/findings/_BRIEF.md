# Workstream brief — Cap v2 round 3 (read this and audit/v3/00-plan.md before anything else)

## Rules of engagement
- Repo: /Users/weso/cap-contracts, branch cap-network, HEAD a843c1d. Foundry 1.6.0-nightly, solc 0.8.36.
- NEVER modify `contracts/`, `test/`, `foundry.toml`, `remappings.txt`, `package.json`, or anything outside `audit/v3/`. Ever.
- Write your findings to `audit/v3/findings/<WS>.md` in the schema below. Write PoC tests under `audit/v3/tests/scratch/<WS>/`.
- Run audit tests with: `FOUNDRY_TEST=audit/v3/tests/scratch/<WS> forge test --match-path 'audit/v3/tests/scratch/<WS>/*' -vv`
  (the env var is REQUIRED and must point at YOUR OWN directory: foundry.toml points test= at test/, and pointing FOUNDRY_TEST at the whole audit/v3/tests tree compiles every other agent's half-written files and fails on their errors). Other agents run forge concurrently; if you hit a compiler cache lock, wait and retry.
- The full-protocol deployer is `test/shared/CapDeployer.sol` (18-dec underlying + 18-dec collateral, real Oracle + ChainlinkAdapter with 8-dec mock feeds, `_setPrice` helper, the test contract holds every role). A 6-decimal-underlying variant is being written by another agent at `audit/v3/tests/shared/CapDeployer6.sol`; if it exists, use it for anything Stablecoin-rounding-related; if not yet, write a minimal one inside your own scratch dir.
- Round-1/2 deliverables (read-only reference): /private/tmp/claude-501/-Users-weso-cap-contracts/3c26655f-4698-4fc0-9c28-9e8265b1e175/scratchpad/prior/audit/ (round 1) and .../prior/audit/v2/ (round 2). Their tests target older commits and will not compile as-is.
- Tools: venv at /private/tmp/claude-501/-Users-weso-cap-contracts/3c26655f-4698-4fc0-9c28-9e8265b1e175/scratchpad/tools/venv (python with numpy/scipy/mpmath, `halmos` 0.3.3, `mutate` = universalmutator). Gambit binary: .../scratchpad/tools/gambit, run with `--solc /Users/weso/.svm/0.8.36/solc-0.8.36 --solc_remappings "@openzeppelin/=node_modules/@openzeppelin/" --solc_allow_paths .`. v1 source worktree (main @ 695c828): .../scratchpad/v1/main. Scratch space for anything not deliverable: .../scratchpad/<WS>/.
- Slither JSON for the appendix: .../scratchpad/logs/slither.json.

## Ground rules
- Assume nothing. Comments and NatSpec claiming "safe because X" are hypotheses to test; say whether each survived.
- No speculative findings. Medium or above requires EITHER a concrete ordered exploit path with attacker capital and net profit, OR a Foundry test that FAILS on current code (paste its real output). Otherwise demote to Informational and say what would settle it.
- No finding inflation. Gas/style go in a final unranked `## Appendix: gas & style` section.
- Read the implementation end to end at least once. Cite `file.sol:Lx-Ly`.
- Severity = impact × likelihood (Immunefi-style): Critical / High / Medium / Low / Informational. Likelihood as preconditions + attacker cost. Curators, market owners, allocators and borrowers are THIRD PARTIES (not protocol-trusted) — Matt's decision. An operator-role holder harming another party's depositors is a real finding.
- The single promise: depositors are protected by underwriter collateral enforced by contract. Any path where a depositor loses money while the system reports itself covered is top-severity and the tiebreaker.

## Finding schema (exact)
### [SEVERITY] Title — one line, states the defect
**Location:** path/to/File.sol:L120-L145 (function name)
**Impact:** what breaks, who loses, how much
**Likelihood:** what must be true; who can cause it; what it costs them
**Exploit path:** numbered steps — starting state, attacker capital, net outcome
**Proof:** failing test name (file), mutant ID, or model output with the threshold; paste real output
**Recommendation:** the specific fix, and its second-order effects
**Invariant broken:** ID from audit/v3/00-plan.md §5, if applicable

## Also report
End your file with `## Invariants` (any plan invariant you broke; any new invariant the code implies) and `## Hypotheses` (for each Pn you own: CONFIRMED / REFUTED / INCONCLUSIVE with one line why). Use finding IDs `<WS>-<n>` (e.g. `B-2`). Reference other workstreams' hypotheses by Pn rather than duplicating them.
