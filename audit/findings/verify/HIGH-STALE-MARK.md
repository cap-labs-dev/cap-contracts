## Verdict: CONFIRMED

## Why (one paragraph, the decisive reason)
The PoC reproduces on current code and does not cheat: `redeem`/`withdraw`/`requestRedeem`/`redeem(requestId)` are inherited ungated from OZ `ERC4626Upgradeable` and `ERC7540AsyncRedeem`, they price off `previewRedeem` → `totalAssets()` = idle + cached `totalDebt`, and nothing on that path (`_withdraw` → `_burn` → empty `_onWithdraw` → `_transferOut` → `Vault.transfer`) calls `_mark`. The staleness is one-directional: a tranche's NAV only moves between marks via `slash` (`Tranche.sol:75-108`, `IVault.withdraw` out) — deposits mint at par and premium is paid in a separate stablecoin leg that never enters the share price — so the cached mark can only over-state, never under-state, and every exit in the window is a transfer from remaining holders to the exiter, not a symmetric fairness/MEV wobble. The exit needs no role at all (my test shows a never-admitted transferee redeems at the stale price), the trigger is an ordinary liquidation, and `IUnderwriter.debt`/`report` NatSpec confirm the team knows `debt` is "an upper bound" refreshed on a keeper "cadence" rather than in the slashing transaction. The extraction is bounded — total over-payment across all exiters ≤ `idle × L / A_stale` (verified to within wei), and zero when the curator has allocated everything — but instant redemption in this vault is *defined* as `previewWithdraw(idle)`, so any vault that offers exits at all carries the idle that makes the loss extractable. Real, unprivileged, bounded fund loss to users with realistic preconditions: High stands, not Critical.

## What I tried (numbered; include commands run and real output snippets)
1. Ran the PoC as-is:
   `FOUNDRY_TEST=audit/tests/scratch/C forge test --match-path 'audit/tests/scratch/C/C1_StaleMark.t.sol' -vv`
   ```
   [FAIL: exiting depositor must not be paid above the true share price: 499999999999999998500 > 414999999999999998841] test_H2_exitAtStaleMarkAfterSlash()
     underwriter true assets: 829999999999999999340
     underwriter reported totalAssets (stale): 999999999999999999000
     alice actually paid: 499999999999999998500
     bob value after report: 330000000000000000180
   [FAIL: queued claim paid at stale mark: 499999999999999998500 > 414999999999999998841] test_H2_queuedExitAlsoAtStaleMark()
   ```
   Read line by line. No mocks, no pranked privileged role on the exit path: alice is pranked only for `redeem`, the liquidator is the real `LIQUIDATOR` role, the slash goes through `market.liquidate` → `Tranche.slash`. The test contract calls `allocate`/`report` as curator/KEEPER (it holds both in `CapDeployer._configureAccess`), which is the honest actor, not the attacker. `_fundUnderwriter` admits alice/bob via the real depositor role.
2. Production wiring (`contracts/cap/Registry.sol:410-448 _configureUnderwriterRoles`): `allocate/deallocate/deallocateAsync/finalizeDeallocateAsync/setDefaultTranche/setVestingPeriod` → curator operator role; `report` → `CapRoles.KEEPER`; `addTranche/removeTranche` → ADMIN; `deposit/mint` → per-vault depositor role. `redeem`, `withdraw`, `requestRedeem`, `redeem(requestId)`, `withdraw(requestId)` are not in the table and `Underwriter.sol` does not override them with `restricted`. Matches the finding.
3. Angle (a), permissionless re-mark on the redeem path: none. `ERC4626Upgradeable.redeem` computes `previewRedeem` (line 250) before `_withdraw`; `ERC7540AsyncRedeem._withdraw` (`:255-267`) does `_checkAllowance → _burn → _onWithdraw (empty) → _transferOut`; `Underwriter._transferOut` is a bare `IVault.transfer`. `Vault.transfer` has no callback. The finding's "no permissionless way to refresh the mark" is however slightly over-stated — see corrections: `deposit` → `_transferIn` → `_allocate(defaultTranche)` → `_mark(defaultTranche)`, so with a default tranche set any admitted depositor re-marks it with a 1-wei deposit, and the curator can re-mark any tranche with `deallocate(t, 0)` (`Underwriter.sol:127-129` marks outside the `if`).
4. Angle (b), bound. Wrote `audit/tests/scratch/verify/HIGH-STALE-MARK/StaleMarkBound.t.sol`; run with
   `FOUNDRY_TEST=audit/tests/scratch/verify/HIGH-STALE-MARK forge test --match-path 'audit/tests/scratch/verify/HIGH-STALE-MARK/*' -vv`
   ```
   [PASS] test_boundIsIdleTimesLossFraction()
     idle: 200000000000000000000
     unrecognised loss L: 272000000000000000000
     alice over-paid: 54399999999999999986
     bound idle*L/A: 54400000000000000054
     bob fair: 291199999999999999736
     bob after report: 263999999999999999736
   [PASS] test_fullyAllocated_nothingExtractable()   // maxRedeem == 0, redeem(1) reverts, claimableRedeemRequest == 0
   ```
   Derivation: an exiter burning `s` shares is paid `s·A_stale/S` against fair `s·(A_stale−L)/S`, over-payment `s·L/S`; `maxRedeem = min(balance, instantUnlockedSupply)` with `unlockedSupply = previewWithdraw(idle) = idle·S/A_stale`, so over-payment ≤ `idle·L/A_stale`. Each exit consumes the idle it is paid from, so this is the cumulative cap across all exiters, and the queued path (`claimableRedeemRequest` = `settledQueue + unlockedSupply()`) is capped by the same idle. Idle = 0 ⇒ nothing extractable. The finding's "f × L" is the per-exiter cap only when idle ≥ f·A_stale.
5. Angle (c), permissioned depositors. `_update` override (`Underwriter.sol:389-400`) only checkpoints premium; shares are freely transferable (the `deposit` NatSpec says so). Test:
   ```
   [PASS] test_transfereeWithoutDepositorRoleRedeemsAtStaleMark()
     outsider fair: 414999999999999998840
     outsider paid: 499999999999999998500
   ```
   `_mayDeposit(uw, outsider) == false` yet outsider redeems at the stale mark. The exiter is "first-out", but first-out at a price the contract *knows* is an upper bound is the defect; admission does not reduce the set of possible exiters to trusted parties.
6. Angle (d), keeper cadence. `IUnderwriter.report` NatSpec (`:131-136`): "only the way to reach a position nothing else has touched — a slash, most of all. The premium sweep is what makes it worth calling on a cadence rather than on demand." `IUnderwriter.debt` NatSpec (`:194-198`): "A slash in between moves the position without moving this, so it is an upper bound." Existing test `test/integration/AccountingIntegrity.t.sol:752-786` documents the earlier phantom-debt fix and says "the deposits were allocated straight on, so no one can exit before the curator acts" — i.e. the team's model is idle = 0 under `defaultTranche`. Nothing in `contracts/` or NatSpec says the keeper reports in the liquidation transaction, and `liquidate` does not call into any underwriter; the keeper is a separate role from the LIQUIDATOR. "Cadence" is an explicit admission of a window. Operational mitigation lowers likelihood but does not remove the defect; funds are extractable inside the window without any role.
7. Angle (d'), default-tranche config reachability:
   ```
   [PASS] test_dustDepositReMarksDefaultTranche()
   ```
   With `setDefaultTranche` set, deposits go straight in (idle = 0). Curator `deallocate(t, half)` frees a buffer and marks fresh; a later liquidation leaves the mark stale with idle > 0 — so the state is reachable in the intended configuration too (any rebalance/buffer + a slash). A 1-wei deposit by an admitted depositor then refreshes the mark, and alice is paid fairly afterwards. So the default-tranche config has a depositor-side mitigation the finding missed, but it only covers the default tranche and only if someone other than the exiter acts first.
8. Angle (e), symmetry. `Tranche.sol` moves assets only via `_transferIn` (deposit, mints shares at par: no per-share change), `_transferOut` (redeem) and `slash` (`IVault.withdraw` to recipient). Premium is claimed as `stablecoin` via `report → ITranche.claim` and vested through `PremiumVesting`, never entering `totalAssets`. So between marks the per-share NAV of a tranche position can only fall (barring a gratuitous `vault.transfer` donation to the tranche). The stale mark is always ≥ true; an exiter is never under-paid on the asset leg. The only thing an early exiter forfeits is unvested/unswept premium, which is a different token and by design. Not symmetric; this is a one-way transfer, not fairness/MEV.
9. Curator-side mitigation: `[PASS] test_curatorZeroDeallocateReMarks()` — `deallocate(t, 0)` re-marks without KEEPER. Curator-only.

## Corrections to the finding text (bullet list, or "none")
- "There is **no permissionless way to refresh the mark**" is over-stated. With a `defaultTranche` set, any admitted depositor re-marks *that* tranche via `deposit(1)` → `_transferIn` → `_allocate` → `_mark`; the curator can re-mark any tranche via `deallocate(t, 0)`. Neither is available to the public or covers non-default tranches, and neither happens automatically, so the conclusion holds, but the sentence should say "no permissionless way that does not itself depend on a depositor or the curator acting first".
- The extraction bound is `min(f·L, idle·L/A_stale)` per exiter and `idle·L/A_stale` cumulatively across all exiters (instant and queued), not "f × L … bounded by the idle balance". In the PoC both coincide at 85 because idle = 50 % of A_stale and f = 50 %. When the curator has allocated everything, nothing is extractable.
- Attacker set is wider than stated: the exit needs no role, so any share *holder* (including a transferee never admitted by the curator) can take the stale price. Conversely, "the curator themselves, who can manufacture idle by deallocating an unslashed tranche" is right but that deallocate marks the tranche it touches; the curator's edge is only over tranches it did not touch.
- Add to design-intent: `IUnderwriter.debt` and `report` NatSpec explicitly describe the cache as an upper bound refreshed on a keeper cadence, and `test/integration/AccountingIntegrity.t.sol:752-786` shows the team closed the curator-side phantom-debt leak but left the depositor-side window open on the assumption idle = 0. The recommendation (mark before every preview on entry/exit, plus a permissionless `mark`) is the correct fix; note that a permissionless `mark(tranche)` alone is insufficient because the exiter will not call it — the mark must be inside `redeem`/`withdraw`/`deposit`/`mint`.
- Minor: the recommendation says "the OZ `redeem` computes `previewRedeem` before `_withdraw`, so an `_onWithdraw` hook is too late" — confirmed correct (`ERC4626Upgradeable.sol:250`).

## Residual doubt (what would settle it if still uncertain)
Severity, not existence. The only argument for Medium is operational: if the production KEEPER is a bot that calls `report` on every `Slashed` event in the same block (or the curator never holds idle), the window is one-block-or-less and the exploit degrades to MEV back-running of the liquidation. Nothing in the repo (no deploy script, no NatSpec) commits to that; the NatSpec says "cadence". A statement from the team of the keeper's actual trigger and latency would settle High vs Medium. Under Immunefi scoring, unprivileged extraction of other depositors' funds with only gas cost, triggered by an ordinary liquidation, bounded but not dust, is High.
