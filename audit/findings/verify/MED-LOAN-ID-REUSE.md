# MED-LOAN-ID-REUSE — verification

## Verdict: CONFIRMED (Medium)

## Why (one paragraph, the decisive reason)
The mechanism is exactly as described and reproduces under production role wiring with each step pranked to
only the role it needs: `extend(loanCount, minTerm)` from the owner operator role (or `extendAdmin` from
KEEPER) seeds `expiry` on an unused id at zero premium, `borrowMore` from the borrower role draws on it for a
minimum-term premium, and the next `borrow` (`id = loanCount++`) reuses that id and overwrites `expiry` to a
full term with no further charge. At $10M the pair pays 16,256 cUSD for 30 days of exposure against an honest
328,767 — 95.05% avoided — and it is repeatable every month by chunk-migrating the debt onto the next unused id
(round 2: 8,951 vs 222,612 honest, 96% avoided). `totalDebt == creditBackedSupply` stays exact, so this is a
pure underpayment to stcUSD holders and tranche depositors, not an unbacked mint. No single role can do it:
the borrower alone is stopped by `LoanExpired` (`expiry 0`) on `borrowMore` and by `AccessManagedUnauthorized`
on `extend`/`extendAdmin`; the owner alone cannot `borrow`/`borrowMore`. It needs owner (or keeper) plus
borrower, and the Registry permits one address to hold both (F-I6). Medium rather than High because two
permissioned operator roles (or one operator wearing both hats) are required and no principal is at risk;
Medium rather than Low because the leak is silent, sustained, and defeats the one guard governance has on the
liquidity price (`minimumMarketMultiplier = 1e27`): the owner may already zero the underwriter premium openly
via `setUnderwriterRate(0)`, but cannot legitimately discount the liquidity premium owed to stcUSD by any
amount — and this path discounts it ~93%. NatSpec says `borrowMore` is "against an existing loan"; nothing
sanctions touching an id before `borrow` creates it. The one-line fix (`id >= loanCount` revert) has no
legitimate-flow cost.

## What I tried (numbered; include commands run and real output snippets)

1. Read `contracts/cap/market/FixedMarket.sol` in full. Confirmed: no function checks `id < loanCount`;
   `extend` on `expiry[id] == 0` takes the `block.timestamp >= previousExpiry` branch, `_rollFromNow(0, ext)`
   returns `ext + block.timestamp` (arrears since epoch), `_extend` charges `_chargePremiumForTerm(id, debt[id]
   == 0, ...)` = 0, `termMultiplier` clamps the >1e27 term ratio to 1e27 so the IRM does not revert,
   `healthiness()` returns 1e27 on zero debt so the post-check passes. `extendAdmin` on an unused id passes
   `block.timestamp < 0 + grace` whenever the chain clock is past `grace` (always, outside Foundry's t=1).
   `borrow` unconditionally does `expiry[id] = block.timestamp + term` and `_borrow` does `debt[id] +=`.

2. Read `Registry._configureMarketRoles` (`contracts/cap/Registry.sol:321`): `extend` -> owner operator role;
   `borrow`/`borrowMore` -> borrower operator role; `extendAdmin` -> KEEPER. `_createMarket` accepts
   `_marketOwner == _borrower` (F-I6). IRM `updateUnderwriterRate` has only an upper bound (rate 0 allowed);
   `updateMarketMultiplier` is bounded below by `minimumMarketMultiplier` (1e27 in the deployer config).

3. Ran the workstream PoC:
   `FOUNDRY_TEST=audit/tests/scratch/D forge test --match-path 'audit/tests/scratch/D/D9_PhantomLoanId.t.sol' -vv`
   ```
   [FAIL: 30 days of exposure must cost the 30-day premium: 6535159817351598172 < 131506849315068493150]
     honest 30-day premium on 4000: 131506849315068493150
     premium paid (1 day)         : 6502283105022831050
     premium paid in total        : 6535159817351598172
   ```
   PoC caveat: `market.extend(id, 1 days)` is called by the test contract, which in `CapDeployer` is
   simultaneously market owner, GOVERNOR, KEEPER, GUARDIAN and ADMIN. It does not cheat (owner is the correct
   role and `AccessManaged` has no admin bypass), but it does not isolate the role. My test does.

4. Wrote `audit/tests/scratch/verify/MED-LOAN-ID-REUSE/V_LoanIdReuse.t.sol` with a separate `owner`,
   `keeper`, and `defaultBorrower`, market created directly via `registry.createFixedMarket` and every
   owner-role setter pranked. Ran
   `FOUNDRY_TEST=audit/tests/scratch/verify/MED-LOAN-ID-REUSE forge test --match-path 'audit/tests/scratch/verify/MED-LOAN-ID-REUSE/*' -vv`
   ```
   [PASS] test_borrowerAloneCannotSeedPhantomId()        -- extend/extendAdmin: AccessManagedUnauthorized; borrowMore: LoanExpired
   [PASS] test_ownerAloneCannotDraw()                    -- extend seeds (expiry = now+1d, debt 0); borrow/borrowMore: AccessManagedUnauthorized
   [PASS] test_keeperCanSeedInsteadOfOwner_noHealthCheck() -- extendAdmin(unused, 1d) returns 1 days + block.timestamp; borrower then completes
   [PASS] test_quantify_10M_splitByRecipient()
     honest 30d liquidity premium (stcUSD): 164383561643835616438356
     honest 30d underwriter premium (tranche): 164383561643835616438356
     paid liquidity premium (stcUSD): 10776255707762557077625
     paid underwriter premium (tranche): 5479452054794520547945
     stcUSD shortfall: 153607305936073059360731
     tranche shortfall: 158904109589041095890411
     avoided bps of honest total: 9505
   [PASS] test_ownerOpenLever_underwriterRateZero_leavesLiquidityPremium()
     liquidity premium owner cannot waive (30d, 10M): 164383561643835616438356   (setMarketMultiplier(0.5e27) reverts)
   [PASS] test_repeatable_monthlyRollover()
     honest 30d premium: 222612015584943792672338
     round 1 premium: 16255707762557077625570
     round 2 premium: 8951459352482878816745
   [PASS] test_honestPathsAllChargeFullTerm()
     honest 30d premium: 328767123287671232876712
     borrow 1d + extend 29d premium: 216535085590375513438000
   Suite result: ok. 7 passed; 0 failed
   ```
   The $10M test also asserts `market.totalDebt() == stablecoin.creditBackedSupply()` after the exploit (I3
   intact) and that `borrowMore` still succeeds at day 29 (the 30-day term is real).

5. Checked the arithmetic by hand. Liquidity paid = 10M x 20% x (1/365) x termMultiplier(1/30) where
   termMultiplier = 1 + slope x (1 - 1/30) = 1.9667 -> 10,776 (matches). Underwriter paid = 10M x 20% x 1/365 =
   5,479 (no term multiplier on the underwriter leg; matches). Paid fraction of honest: liquidity 6.6%,
   underwriter 3.3%, blended 4.95%. With `termMultiplierSlope = 0` the avoided share is 96.7%; with a shorter
   `minimumTermLimit` it tends to 100%; with a longer `maximumTermLimit` it grows further. "95%" is a property
   of the deployer config (30d/1d/slope 1e27), not a constant.

6. Looked for an honest path that re-terms debt cheaply: `borrow(P, 1d)` then owner `extend(id, 29d)` charges
   the whole debt for the whole extension (216,535 vs 328,767 honest quote; the gap is the extension's
   liquidity leg being priced at pre-mint time-weighted utilization, a separate pricing property of
   `_ratesStillToMint`, not this finding). No honest path leaves debt on a term it did not pay for.

7. Checked for an existing mitigation: none. `_creditCheck`/`availableCredit` bound the draw size but not the
   id; `healthiness()` is 1e27 at zero debt; `borrowMore` only checks `expiry` and `minimumTermLimit`.
   IFixedMarket NatSpec: `borrowMore` "against an existing loan"; `extend` documents the expired-roll branch
   for real loans only. No text sanctions unused ids.

## Corrections to the finding text (bullet list, or "none")
- State explicitly that no single role can execute this: borrower alone fails (`LoanExpired` on `borrowMore`,
  `AccessManagedUnauthorized` on `extend`/`extendAdmin`); owner alone cannot draw. It requires owner-or-keeper
  plus borrower, which the Registry allows to be one address (F-I6). "Routinely the same business" is an
  assumption, not something the code or docs establish — phrase it as "permitted by the Registry".
- Split the loss by recipient and note the owner's existing open lever: the underwriter leg is already
  waivable by `setUnderwriterRate(0)` (F.md trust table), so the leakage the pair could not otherwise
  achieve is the liquidity premium to stcUSD — bounded below by `minimumMarketMultiplier` and here cut ~93%.
  At the deployer's rates that is ~153.6k cUSD per $10M per 30 days; at a production liquidity rate of
  5–10% it is ~39k–78k per $10M per month.
- "95% avoided" is config-dependent (30d/1d term limits, `termMultiplierSlope = 1e27`); give the formula:
  paid fraction = `(minTerm/maxTerm) x termMultiplier(minTerm/maxTerm)` on the liquidity leg and
  `minTerm/maxTerm` on the underwriter leg.
- Add that it is repeatable indefinitely: at day 29 seed the next `loanCount`, migrate the debt in chunks
  within credit headroom (`borrowMore` new id / `repay` old id), then `borrow` dust to re-term. Round 2 in my
  test cost 4% of the honest premium.
- The keeper path needs `block.timestamp >= grace`, true on any live chain (Foundry's t=1 makes a naive test
  revert `StillInGracePeriod`; the PoC does not use the keeper path so it did not hit this).
- `borrow`'s dust principal can be 1 wei, not 1e18; immaterial but the PoC's 1e18 is not a requirement.
- The PoC's `extend` caller holds every role at once (CapDeployer). It is not a cheat (owner is the correct
  role), but the write-up should cite a role-isolated reproduction; mine is at
  `audit/tests/scratch/verify/MED-LOAN-ID-REUSE/V_LoanIdReuse.t.sol`.

## Residual doubt (what would settle it if still uncertain)
Severity hinges on whether the market operator pair is treated as a trusted counterparty for pricing (not just
for repayment). If the protocol's threat model states that the owner+borrower are one KYC'd entity whose
premium underpayment is a business/legal matter rather than a code invariant, this drops to Low. Nothing in
the repo says so; the `minimumMarketMultiplier` guard says the opposite — governance intends the liquidity
price to be a floor the operator cannot lower. A statement of the intended operator trust model would settle
it either way; the fix is one line regardless.
