# R2-MED-WRAPPER-INFLATION — verification of N1 [MEDIUM] "Wrapper first-depositor inflation at zero cost"

## Verdict: CONFIRMED

## Why (one paragraph, the decisive reason)
The PoC reproduces on `3dad5ef` without cheating (the only privileged call, `fundCreditBacked`, stands in for the
`BaseMarket._chargePremium` flow the attacker does not control but merely waits for), and the attacker genuinely
nets a gain rather than griefs: with 1 wei of capital they take `V/2 = 200e18` of the victim's 400e18 on top of the
premium they would have earned anyway as sole staker, and OZ's virtual +1 share does not help because the
"donation" is the premium stream, not the attacker's own cUSD. This is worse than the finding states: after the
attacker exits, the Wrapper is left with `totalSupply == 0` and `totalAssets == 690e18`, so every later deposit
below 690e18 also mints 0 shares — the vault is a permanent zero-share trap, not a one-victim event
(`test_repro_and_residual_poison`). The preconditions are fragile but realistic: they collapse completely if any
single cUSD holder calls `optIn()` directly (a 1000e18 direct staker leaves the Wrapper with 1 wei of premium and
the victim gets 400e18 shares), yet nothing in code or deployment guarantees that, the Wrapper is the named
"Staked cUSD" product surface, and premium charged while `staked == 0` is frozen and later accrues entirely to
the first wei deposited — so the attacker needs no timing luck at all. A 10e18 seed bounds the loss to 22 wei,
which is exactly what `Tranche` already does via `DeadShares` and the Wrapper omits; the inconsistency is the
defect. Medium stands: direct user-fund loss at negligible cost, gated by a launch-window/no-direct-staker
condition the protocol does not currently enforce.

## What I tried (numbered; include commands run and real output snippets)
1. Read `contracts/cap/Wrapper.sol` (no `DeadShares`, no `_decimalsOffset` override → OZ default 0, `initialize`
   opts in with balance 0, `totalAssets = balance + claimable`), `PremiumVesting.optIn/claimable/_accrue`,
   `Stablecoin.fundCreditBacked`. Confirmed `_accrue` with `supply == 0` only bumps `lastUpdate` (premium is
   frozen, not lost).
2. Ran the PoC: `FOUNDRY_TEST=audit/v2/tests/scratch/N1 forge test --match-path
   'audit/v2/tests/scratch/N1/PoC.t.sol' --match-test test_N6b -vv` → `[PASS]`, logs
   `wrapper totalAssets before victim: 981685209050967797685 / victim shares: 0 /
   attacker cUSD out (capital: 1 wei): 690842604525483898843`. OZ `deposit` did not revert on 0 shares.
3. Production wiring: `grep -rn Wrapper contracts/deploy test/deploy` → no hits. `contracts/cap/Wrapper.sol` is
   referenced only by `test/unit/cap/Wrapper.t.sol`; `script/manage/CheckAccess.s.sol:29` imports a stale
   `contracts/token/Wrapper.sol` (`setDonationReceiver`) that no longer exists. So the Wrapper is not yet in the
   `DeployInfra` path, and no seed deposit exists anywhere.
4. Other opt-ins into cUSD: `grep -rn "\.optIn()" contracts` → only `Wrapper.sol:44` (into cUSD) and
   `Underwriter.sol:85` (into the tranche, not cUSD). No contract other than the Wrapper stakes cUSD; direct
   user `optIn()` on the Stablecoin is public.
5. Wrote `audit/v2/tests/scratch/verify/R2-MED-WRAPPER-INFLATION/Verify.t.sol` (4 tests, all pass, run with
   `FOUNDRY_TEST=audit/v2/tests/scratch/verify/R2-MED-WRAPPER-INFLATION forge test --match-path
   'audit/v2/tests/scratch/verify/R2-MED-WRAPPER-INFLATION/*' -vv`):
   - `test_repro_and_residual_poison`: reproduces, then `wrapper supply after exit: 0`,
     `wrapper assets after exit: 690842604525483898842`, `next depositor 100e18 -> shares: 0`.
   - `test_direct_optIn_dilutes_wrapper`: bob `optIn()`s 1000e18 directly → `wrapper totalAssets ...: 1`,
     `victim shares: 400000000000000000000`, `attacker out: 1`. Attack fully collapses.
   - `test_seed_first_deposit_closes_it`: 10e18 seed first → victim shares `4033538025466727971` vs fair
     `4033538025466727970`, `victim rounding loss (wei): 22`; attacker's 1 wei redeems ≤ 200 wei.
   - `test_prefunded_premium_accrues_to_first_wei`: 1000e18 funded, 30 days with nobody staked, then 1 wei
     deposited → `wrapper totalAssets after late 1-wei deposit: 981685209050967797685`. Frozen premium hands
     the whole pot to whoever deposits first; no need for a charge to land after the attacker's deposit.
6. Attacker P&L: out 690.84e18 = 490.84e18 (premium, would be earned anyway as sole staker) + 200e18 (half of
   victim's 400e18). Net gain attributable to the inflation = +200e18 on 1 wei; remaining 200e18 of the victim's
   deposit stays stranded behind the virtual share (and becomes the poison for the next depositor). Real
   extraction, not grief.

## Corrections to the finding text (bullet list, or "none")
- "this is *the* staking entry point": not quite — any cUSD holder can `optIn()` directly on the Stablecoin, and a
  single such staker of ordinary size neutralises the attack entirely (step 5). State the precondition as "no
  direct cUSD opt-in of meaningful size exists" rather than "Wrapper is the only entry point".
- Exploit path step (2) is not required: premium funded before the attacker's deposit is frozen (`staked == 0`)
  and accrues to the first wei afterwards; the attacker can deposit *after* any amount of premium has been
  charged. This strengthens likelihood.
- Impact understates the damage: after the attacker redeems, `totalSupply == 0` with ~690e18 of assets, so every
  subsequent deposit `< 690e18` mints 0 shares and is captured by the next redeemer. The vault stays broken until
  someone deposits more than the stranded assets.
- Scope caveat: `contracts/cap/Wrapper.sol` is not deployed by `contracts/deploy/*` (and `CheckAccess.s.sol`
  points at a deleted `contracts/token/Wrapper.sol`). Note that the fix must land before the Wrapper is added to
  the deploy path, and that the deploy path should also carry the seed if the `DeadShares` route is not taken.
- `_decimalsOffset() >= 6` alone is insufficient here: the premium pot can be arbitrarily large relative to a tiny
  supply, so a virtual offset only shifts the threshold; the seed/dead-shares floor on real supply is the
  necessary part of the fix (with 10e18 seeded, a 1000e18 pot costs a 400e18 depositor 22 wei).

## Residual doubt (what would settle it if still uncertain)
Whether the team intends a protocol seed deposit at Wrapper launch (which is not in any script today). If the
deploy path is amended to seed ≥ 1e18 before the Wrapper is opened, this demotes to Low as a documented 4626
caveat; until that is in code, Medium.
