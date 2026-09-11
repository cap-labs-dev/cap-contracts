# MED-PHANTOM-YIELD — D2 / H3: premium minted against unrecoverable debt

## Verdict: DEMOTE to Low

## Why (one paragraph, the decisive reason)
The mechanism is real and the PoC is honest, but it is not a vulnerability: it is a documented design trade-off whose cost is a slow, bounded dilution that requires prolonged inaction by two protocol roles. `BaseMarket._writeOff` NatSpec says in terms that write-off exists "so the market stops accruing and minting premium against debt nobody will repay", and `IFixedMarket.writeOff` says it is "callable at any time ... [because waiting] would otherwise let the shortfall compound" — the authors know premium accrues on the unrecoverable slice and deliberately made the brake discretionary, because write-off is irreversible (it forgives the borrower's debt) and `unrecoverableDebt` is an oracle-dependent snapshot that a rebound can erase. The economic loss is a transfer, not a destruction of backing: in a counterfactual test `totalAssets` is *identical* (5980.39 cUSD) whether the guardian writes off immediately or after 12 rolls; what changes is that 1,650 more shares claim the same assets, so plain cUSD holders are diluted (the saver's 5,000 cUSD redeems for 1,665 instead of 2,238) in favour of stcUSD/tranche holders. That dilution is ~2.4% of the unrecoverable slice per monthly roll (~0.08%/day) — the PoC needs a full year of KEEPER rolling and GUARDIAN not writing off to reach its figures. The "$327 cashed out of the reserve ahead of depositors" framing is wrong: the redemption curve priced the underwriter's exit at 327 against a flat-ratio value of 607, retired 855 of badDebt, and *raised* the saver's redeemable value by 203; the transfer happens at mint time (dilution), not at redemption. Under Immunefi-style scoring, a bounded redistribution among protocol participants that needs months of privileged inaction, is explicitly acknowledged in the NatSpec, and has an at-any-time one-transaction remedy is Low. The defect worth keeping is narrower than "rolling exists": it is that the brake is weaker than documented (see corrections) and that `extendAdmin`'s NatSpec steers an automated keeper into rolling blindly.

## What I tried (numbered; include commands run and real output snippets)

1. **Reachability under production wiring.** `contracts/cap/Registry.sol:358` sets `IFixedMarket.extendAdmin.selector` to `CapRoles.KEEPER`; `:348-350` sets both `writeOff` selectors to `GUARDIAN`; `FloatingMarket.chargePremium` is unrestricted (`FloatingMarket.sol:106`). `ConfigureAccessControl.sol:20-21` grants KEEPER and GUARDIAN to `users.keeper` / `users.guardian`. Both are protocol-operated roles; no attacker role is involved. `DeployInfra.sol:88` uses `lt: 0.8e27`, the same as the test deployer. Reachable, but only through operator action + operator inaction.

2. **Ran the PoC.** `FOUNDRY_TEST=audit/tests/scratch/D forge test --match-path 'audit/tests/scratch/D/D2_RollDefaulted.t.sol' -vv`. All three tests fail as the finding reports (the failing asserts are the author's "should" properties, not reverts):
   ```
   [FAIL: write-off should not exceed the shortfall that existed before the rolls: 4815722449171194887454 != 4019607843137254901959] test_H3_keeperRollsMintUnbackedYieldOnDefaultedLoan()
     debt growth (all phantom)       : 1650774693945761037669
     badDebt recognised at write-off : 5670382537083015939628
     senior underwriter claimed cUSD : 1182382840084594765910
     USDC redeemed from the reserve  : 327722752172773713736
   [FAIL: shortfall should not compound ...: 5630659394151735795194 != 4019607843137254901961] test_H3_floatingAccruesOnUnrecoverableDebtWithoutAnyRole()
   [FAIL: a tranche with no capital should earn no premium: 887132370846222092005 != 0] test_H3_slashedToZeroTranchesStillReceivePremiumOnRoll()
   ```
   Read line by line: no pranked roles it should not have beyond the test contract holding KEEPER/GUARDIAN/GOVERNOR (that is the deployer's design); no mocks hide a check. Two caveats: `capConfig.stablecoinYield` is `makeAddr("stcUSD")` — a bare EOA, so "cUSD minted to stcUSD" is minted to nobody in particular, and the "stcUSD stakers" who supposedly profit do not exist in the test; and the scenario is extreme (one loan = 50% of supply, 80% unrecoverable) so the percentage dilution is far larger than a diversified pool would see. Note also the assert's actual value `4815...` is `badDebt` *after* the underwriter's redemption retired 855 of it — the PoC itself shows the redemption reducing badDebt, contrary to its own framing.

3. **Counterfactual to attribute the loss** — `audit/tests/scratch/verify/MED-PHANTOM-YIELD/Verify_PhantomYield.t.sol`, run with `FOUNDRY_TEST=audit/tests/scratch/verify/MED-PHANTOM-YIELD forge test --match-path 'audit/tests/scratch/verify/MED-PHANTOM-YIELD/*' -vv` (4 passed). Same setup as the PoC; snapshot after the crash, branch 1 writes off at once, branch 2 rolls 12x then writes off:
   ```
   BRANCH 1: prompt write-off, no rolls
     totalSupply            : 9999999999999999999998
     badDebt                : 4019607843137254901959
     totalAssets            : 5980392156862745098039
     saver previewRedeem 5k : 2238060868519186815831
   BRANCH 2: 12 rolls, then write-off
     totalSupply            : 11650774693945761037667
     badDebt                : 5670382537083015939628
     totalAssets            : 5980392156862745098039
     saver previewRedeem 5k : 1665217611540541199729
   supply growth (phantom cUSD)  : 1650774693945761037669
   totalAssets delta (2 - 1)     : 0
   saver redeemable delta (2 - 1): -572843256978645616102
   ```
   `totalAssets` is byte-identical: the reserve (5,000 USDC) and the backing are untouched. The whole effect is 1,650 extra shares diluting the pool. Who gained: senior tranche 1,107, junior 58, `stablecoinYield` EOA 486 (from the PoC logs). Who lost: every non-recipient cUSD holder pro rata — the saver's 5,000 cUSD lost 573 of redeemable value (11.5%, because this pathological pool is half one bad loan). The borrower's 4,841 drawn cUSD is diluted the same way but they have defaulted.

4. **"Cashed $327 out of the reserve ahead of depositors" — tested and refuted.** Continuing branch 2, the senior underwriter claims 1,182 cUSD (6h vesting waited out) and redeems:
   ```
   uw claimed cUSD               : 1182382840084594765910
   uw USDC received              : 327722752172773713736
   uw cUSD value at flat ratio   : 606922135995425226640
   badDebt retired by uw exit    : 854660087911821052174
   saver redeemable delta (post-redeem - pre): 203171387314957248704
   ```
   The exit was priced at 327 against a flat-ratio value of 607 (`Stablecoin._convertToAssets` curve, "exiting first is the worst time to exit"); `_onWithdraw` burned 855 off `badDebt`; the saver's redeemable value went *up* by 203. The underwriter did extract 327 of real USDC they would not otherwise have had, but they paid 1,182 shares for it and repaired the remaining holders in doing so. The transfer to the underwriter occurred at mint (step 3), not at redemption, and the redemption is strictly favourable to whoever stays.

5. **Is write-off a sufficient brake?** No — this cuts against the finding's own framing and is the most useful correction. After a prompt write-off the debt sits at exactly `recoverableDebt` (980), so each subsequent roll re-creates an unrecoverable slice:
   ```
   residual debt after write-off : 980392156862745098039
   debt after 12 more rolls      : 1270152081531926832054
   unrecoverable re-accrued      : 289759924669181734015
   debt after liquidation        : 0
   minted by a roll on 0 debt    : 0
   ```
   Only LIQUIDATOR liquidation of the residual ends accrual (a roll on zero debt mints nothing). So the brake is "write-off, then liquidate", two roles, and write-off alone must be repeated after every roll. The `_writeOff` NatSpec ("liquidation stays viable afterwards") implies this sequence but does not say the guardian's job is unfinished until the liquidator acts.

6. **Floating market: the poke is not the cause.** `unrecoverableDebt()` is a view over the IRM index and grows with time alone; nothing is minted until a call, and the guardian's own `writeOff()` calls `_chargePremium()` first:
   ```
   unrecoverable t0              : 4019607843137254901961
   unrecoverable t0+360d, no call: 5617688949298344325583
   cUSD minted meanwhile         : 0
   minted by the write-off call  : 1598081106161089423622
   ```
   So in the floating market the guardian cannot write off *without* minting whatever accrued during their latency. The "twelve permissionless pokes" in the PoC are theatre — one poke, or the write-off itself, mints the same amount. This is also why "no role at all" is not an aggravating factor: the accrual is the interest-rate model, not an access-control gap.

7. **Griefing lever in the recommended fix (angle b).** `unrecoverableDebt = debt - capital/(1+bonus)`; healthy means `debt <= lt*capital`; so a healthy market can be unrecoverable only if `lt*(1+bonus) > 1`. Deployer/production: `0.8 * 1.02 = 0.816`, tested:
   ```
   lt * (1+bonus) (ray)          : 816000000000000000000000000
   unrecoverable at max draw     : 0
   ```
   Governance *can* set `lt` up to 1e27 (`setLt`) and bonus up to 0.1e27 (`InterestRateModel.sol:210`), giving up to 1.1, at which point a max-draw borrower would be "unrecoverable" while healthy and a `min(debt, recoverable)` charge would discount them ~9% and a `revert while unrecoverable>0` guard would block keeper rolls on a performing loan. Underwriters cannot withdraw the market into unrecoverability (`lockedValue = debt/(lt-buffer) > debt/(1+bonus)`). So the lever exists only under governance-chosen aggressive params — a caveat to document, not a blocker. The bigger second-order problems with the recommendation: (i) `min(debt, recoverableDebt())` is not expressible in the floating market's scaled-debt/index model without a rewrite; (ii) auto-`recognizeBadDebt` inside `_chargePremium` would make an *irreversible* debt forgiveness triggerable by anyone (floating `chargePremium` is permissionless) during a transient oracle dip — strictly worse than the status quo.

8. **Design intent (angle c).** `IFixedMarket.extendAdmin` NatSpec: rolling "rather than by liquidation, which would take collateral from the underwriters instead of charging the borrower ... Health is not checked". That rationale is sound while the borrower can still pay (unhealthy but recoverable, i.e. overdue with collateral still covering debt); it has no content once `unrecoverableDebt > 0`, because "charging the borrower" charges someone who has already walked away. So the defect is narrower than the finding's title: rolling is fine, and the unchecked health is fine; what is missing is that the NatSpec does not tell the keeper to stop at `unrecoverableDebt() > 0`, and a keeper bot implemented from this doc will roll blindly. That is a documentation/defense-in-depth gap.

## Corrections to the finding text (bullet list, or "none")
- Severity: Low, not Medium. Requires KEEPER action plus GUARDIAN and LIQUIDATOR inaction over months; loss rate ~0.08%/day of the unrecoverable slice; explicitly acknowledged in `_writeOff` and `IFixedMarket.writeOff` NatSpec.
- "That cUSD is real and fungible — ... redeem it against the reserve at par, ahead of the depositors" is wrong. Redemption during a shortfall is priced below the flat backing ratio (`Stablecoin._convertToAssets`), retires bad debt (`_onWithdraw`), and improves the position of remaining holders (saver +203 after the underwriter's exit). Nobody redeems "at par"; the harm is dilution at mint time.
- "$327 of USDC leaves the reserve ... that other depositors were counting on": the underwriter burned 1,182 cUSD (flat value 607) for 327 USDC. The remaining holders are better off after that exit than before it. Delete or reframe as "the underwriter converted 1,182 phantom cUSD into 327 real USDC".
- "the only brake is a discretionary GUARDIAN write-off": incomplete. Write-off leaves debt at exactly the recoverable level, so the next roll re-creates a shortfall (+290 on a 980 residual over 12 rolls). The brake is write-off **followed by** LIQUIDATOR liquidation of the residual; write-off alone must be repeated per roll. This is a stronger and more accurate operational point than the one the finding makes.
- Floating "does the same with no role at all — twelve permissionless pokes": the pokes are irrelevant. `unrecoverableDebt()` grows as a view with time; one call (including the guardian's own `writeOff()`, which calls `_chargePremium()` first) mints the whole accrued amount. Not an access-control aggravator.
- Quantify the loss as dilution: `totalAssets` is unchanged (5980.39 in both branches); 1,650 extra shares; a plain 5,000-cUSD holder loses 573 of redeemable value in this (pathological, 50%-of-supply) pool. Recipients: senior 1,107, junior 58, `stablecoinYield` 486.
- The test deployer's `stablecoinYield` is a bare EOA (`makeAddr("stcUSD")`); "stcUSD stakers ... claim it" is not demonstrated, only cUSD minted to an address.
- Recommendation caveats: `min(debt, recoverableDebt())` does not fit the floating index model; auto-write-off inside `_chargePremium` makes an irreversible forgiveness triggerable permissionlessly on an oracle wick — do not adopt. A cheap defense-in-depth is a `revert` in `extendAdmin` when `unrecoverableDebt() > 0` (safe while `lt*(1+bonus) <= 1`, which production satisfies at 0.816; document that constraint), plus a NatSpec line telling the keeper that an unrecoverable loan is written off and liquidated, not rolled.
- The sub-claim "tranches with zero capital still receive premium" (test 3) is the same root cause and needs no separate invariant; after a full liquidation `unrecoverableDebt == debt`, one write-off zeroes it and nothing further mints.

## Residual doubt (what would settle it if still uncertain)
- Whether the team treats GUARDIAN as a fast automated role or a slow multisig. If the guardian is expected to wait for price recovery before writing off (a legitimate reading of the "irreversible" design), the leak persists by design for the duration and the argument for a structural `extendAdmin` guard strengthens — still Low, since the transfer is bounded and redistributive, but worth a documented operational runbook.
- The dilution estimate scales with (phantom mint / total supply); a production pool with many markets would see a far smaller percentage than the 11.5% here. Nothing more to test on the code side.
