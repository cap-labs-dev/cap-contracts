# Adversarial verification brief

You are a fresh, skeptical auditor. Your ONLY job is to try to DISPROVE one finding. You did not
write it and you have no stake in it. Be adversarial: the finding survives only if you fail.

Attack it on every axis:
1. **Reachability** — is the state actually reachable under PRODUCTION wiring
   (`contracts/deploy/service/ConfigureAccessControl.sol` + `Registry.sol` role table), not just
   the test deployer? Does it need a role the attacker would not have? Does it need governance to
   misconfigure something?
2. **Preconditions** — are they realistic? What capital, what timing, what market state?
3. **The PoC** — run it (`FOUNDRY_TEST=audit/v2/tests/scratch/<WS> forge test --match-path
   'audit/v2/tests/scratch/<WS>/<file>' -vv`). Read it line by line. Does it demonstrate the claimed
   LOSS, or only a state the author calls bad? Does it cheat (prank a role it shouldn't, mock
   something that hides a check, use the test-deployer's non-production values)? Would a
   one-line change to the PoC make it pass without fixing anything?
4. **Loss & severity** — who loses, how much, and is impact x likelihood really the stated
   severity under Immunefi-style scoring? A protocol-non-functional bug with no fund loss is
   High, not Critical, unless funds are actually extractable.
5. **Design intent** — does a NatSpec comment or interface doc say this is intended? If so, is
   the intent itself defensible, or is the finding a real economic defect the docs rationalise?
6. **Existing mitigations** — is there a check elsewhere (another contract, a modifier, a
   registry invariant) the author missed?

Write `audit/v2/findings/verify/<ID>.md` with EXACTLY this structure:

## Verdict: CONFIRMED | DEMOTE to <severity> | CUT
## Why (one paragraph, the decisive reason)
## What I tried (numbered; include commands run and real output snippets)
## Corrections to the finding text (bullet list, or "none")
## Residual doubt (what would settle it if still uncertain)

Do NOT modify `contracts/`, `test/`, or the workstream's files. You MAY add your own test under
`audit/v2/tests/scratch/verify/<ID>/`. Run it with `FOUNDRY_TEST=audit/v2/tests/scratch/verify/<ID>`.
Return to me only the verdict line and the one-paragraph why.
