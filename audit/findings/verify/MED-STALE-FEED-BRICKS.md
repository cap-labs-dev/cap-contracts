# MED-STALE-FEED-BRICKS — adversarial verification

Finding: `audit/findings/C.md` "[MEDIUM] One stale oracle feed on any tranche bricks liquidation,
write-off, borrowing and every tranche's redemption for the whole market"

## Verdict: CONFIRMED

## Why (one paragraph, the decisive reason)
The mechanism is real under production wiring and is not covered by the design-intent NatSpec: `Tranche.getPrice` argues fail-closed for *that tranche's own* figure, but `BaseMarket.totalCapital`/`lockedValue` sum every tranche, so a dead feed (primary and backup) on a 0.1 % junior tranche makes `healthiness`, `maxLiquidatable`, `unrecoverableDebt`, `liquidate`, `writeOff`, `borrow` and the senior tranche's `maxRedeem` all revert while `repay` and premium accrual keep running — the PoC reproduces exactly. The concrete loss path is not the 24 h of interest (0.274 cUSD on 500, and healthiness at 1.05 stays above 1 so nothing was liquidatable anyway) but a crash on the *priced* collateral coinciding with the outage: on an identical price path (A 0.655 → 0.60 → 0.459 over 24 h) the live-feed path liquidates twice, leaves 0 unrecoverable debt and 84 USD of underwriter residual, while the outage path leaves the senior tranche wiped to zero and 49.6 cUSD of unrecoverable (avoidable) bad debt on cUSD holders. Two things the finding gets wrong actually reinforce it: the claimed ADMIN `setTranches` escape hatch reverts `Unhealthy()` in exactly the crash scenario where it is needed, so the only working remedy is ADMIN re-pointing the feed (`Oracle.setSource/setBackup`, role 0, no delay). Severity: Immunefi v2.3 lists "temporary freezing of funds" as High, but there is no attacker, the trigger is a double-feed outage on an asset governance itself chose, and a delay-free ADMIN fix exists, so realised loss requires outage + crash + governance inaction. Impact High × likelihood Low = Medium stands.

## What I tried (numbered; include commands run and real output snippets)

1. **Ran the PoC as written.**
   `FOUNDRY_TEST=audit/tests/scratch/C forge test --match-path 'audit/tests/scratch/C/C3_OracleBricksLiquidation.t.sol' -vv`
   ```
   [FAIL: PriceError(0x3Cff...854E)] test_oneStaleFeedBricksLiquidationAndRedemption()
     market.healthiness: REVERT  market.maxLiquidatable: REVERT  market.unrecoverableDebt: REVERT
     market.availableCredit: REVERT  market.writeOff (GUARDIAN): REVERT
     senior.totalCapital (own feed fine): ok  senior.unlockedSupply: REVERT  senior.maxRedeem(alice): REVERT
     junior.unlockedSupply: REVERT  market.repay: ok
   ```
   Reproduces. No cheating: `defaultLiquidator` holds `CapRoles.LIQUIDATOR` (matches `Registry._wireMarket` L361-364); `writeOff` is probed from the deployer which is GUARDIAN in tests, and reverts on `PriceError`, not on role.

2. **Checked whether the mock hides the production backup fallback (angle a).** `test/shared/mocks/MockOracle.sol` has no backup path; `contracts/cap/oracle/Oracle.sol:_priceOne` reads `_source` then `_backup`, and `_read` returns 0 on a stale reading, so the mock's `PriceError` is exactly the production behaviour *after* both entries have failed. A backup mitigates likelihood only: `grep -rn setBackup contracts/deploy script` returns nothing, so no deploy path configures one; it is governance discretion. Two independent feeds for a long-tail junior asset being stale at once is unlikely but that is the stated precondition ("feed outage (primary and backup)").

3. **Traced the revert paths in source.** `BaseMarket.totalCapital` (L283-288) and `lockedValue` (L270-281) call `ITranche.totalCapital()` on every tranche; `Tranche.totalCapital` (L281-283) and `unlockedSupply` (L271-278) divide by `getPrice()` (L328-331), which bubbles `IOracle.PriceError`. `ERC7540AsyncRedeem.maxRedeem` → `instantUnlockedSupply` → `unlockedSupply` (L163-167, 189-193), so both instant and queued claims (`claimableRedeemRequest` L129) are blocked. `FloatingMarket.repay` and `_chargePremium` never touch the oracle. All as claimed.

4. **Checked production roles (`contracts/deploy/service/ConfigureAccessControl.sol`, `Registry.sol` L320-372).** `liquidate` = LIQUIDATOR, `writeOff` = GUARDIAN, `setTranches` = ADMIN, `borrow` = borrower operator. `Oracle.setSource/setBackup` are `restricted` with no target-function role set, so under AccessManager they resolve to role 0 = `CapRoles.ADMIN`, granted with execution delay 0. No attacker role is needed (there is no attacker); no governance misconfiguration is needed beyond choosing a tranche asset whose feeds can die.

5. **Design intent (angle b).** `Tranche.sol` L317-327 justifies fail-closed for *this* tranche's figure ("a frozen feed is worth more to a borrower than a missing one"); `test/integration/Tranche.t.sol:test_getPrice_rejectsAPriceOlderThanItsWindow` tests only the single-tranche case. Nothing in `IBaseMarket.sol`/`ITranche.sol` NatSpec addresses cross-tranche contagion (`grep -n -i "stale\|oracle" contracts/interfaces/IBaseMarket.sol` → one unrelated hit). The intent is defensible for the stale tranche itself; it is silent on the design defect the finding names.

6. **Quantified the loss path with my own test** `audit/tests/scratch/verify/MED-STALE-FEED-BRICKS/Verify.t.sol` (senior 1000 A, junior 1 B, debt 500, A priced to health 1.05, lt 0.8, bonus 2 %, targetHealth 1.25, underwriter rate 20 % APR).
   `FOUNDRY_TEST=audit/tests/scratch/verify/MED-STALE-FEED-BRICKS forge test --match-path 'audit/tests/scratch/verify/MED-STALE-FEED-BRICKS/Verify.t.sol' -vv` → `7 passed; 0 failed`.

   - `test_b1` — 24 h outage, **no price move**:
     ```
     t0            healthiness 1.050  totalDebt 500.000
     t+24h         healthiness 1.0494 totalDebt 500.274  extra debt accrued over 24h: 0.274
     liquidate -> revert Healthy()
     ```
     Pure time delay costs nothing avoidable: 0.055 % extra debt, minted to underwriters/stakers as premium, and the market was never liquidatable.

   - `test_b2` — same crash path, **live feeds** (A 0.655 → 0.60 at t+2h → 0.4587 at t+24h):
     ```
     liq#1 repaid 332.32  slashed 338.97 A   -> health 1.25, debt 167.70
     liq#2 repaid 113.99  slashed 116.27 A   -> health 1.25, debt 53.79
     FINAL: senior.totalCapital 84.05 USD (183.24 A), unrecoverableDebt 0
     ```

   - `test_b3` — same crash path, **junior feed stale** for the 24 h:
     ```
     t+2h, A=0.60, B stale: liquidate REVERT, writeOff REVERT
     t+24h feed back: healthiness 0.735, unrecoverableDebt 49.59
     liq repaid 450.69  slashed 459.70 A (everything)
     FINAL: senior.totalCapital 0, totalDebt 49.59, unrecoverableDebt 49.59
     AVOIDABLE bad debt vs live-feed path: 49.587773166759285416
     ```
     Underwriters lose their 84 USD residual and cUSD holders inherit 49.6 of bad debt that the live-feed path never created. The loss is driven by the price move, not by the interest.

7. **Tested the "every tranche" claim (angle: corrections).** `test_c1`: senior feed stale → `senior.maxRedeem` REVERT, `junior.maxRedeem(bob)` returns (0, because locked at health 1.05) without reverting. `lockedValue` walks from the junior end and breaks at the asking tranche, so a stale feed on tranche *i* blocks tranche *i* and everything senior to it, not tranches junior to it. With the junior-most feed stale (the PoC), every tranche is blocked.

8. **Tested the claimed ADMIN `setTranches` escape hatch.** `test_d1`: junior stale, A = 0.60 (unhealthy on the senior alone) → `setTranches([senior])` reverts with `IBaseMarket.Unhealthy.selector` (`_setTranches` L404). `test_d2`: same call while still healthy succeeds and liquidation/redemption work afterwards. So the hatch only works *before* the crash the finding is about.

9. **Tested the remedy that does work.** `test_d3`: re-posting B's price (models ADMIN `setSource`/`setBackup` to any adapter returning `(price, timestamp)` — `_read` only abi-decodes) restores `liquidate` and `maxRedeem` in the same block. Sole adapter in repo is `ChainlinkAdapter.sol`; ADMIN would need a replacement feed or a purpose-built adapter, one tx, no timelock in the role table.

10. **Angle (c), `repay`.** Works throughout (PoC and my test). It mitigates only if the borrower is solvent and willing; borrowers are whitelisted operators, which helps likelihood, but the protocol's promise to underwriters is liquidation, not borrower goodwill, and the write-off path is blocked too.

11. **Angle (d), severity.** Immunefi v2.3 smart-contract table (fetched): High includes "Temporary freezing of funds"; Medium includes "Griefing (no profit motive for an attacker, but damage to the users or the protocol)" and "Smart contract unable to operate due to lack of token funds". Nominally the freeze is High-tier impact and the avoidable-bad-debt path makes it worse. Against that: zero attacker capital or trigger (a feed outage is not an exploit), the asset with thin feeds is governance's own choice, a backup feed halves the likelihood again, and ADMIN has an immediate fix. Realised loss requires three coincidences (double-feed outage, crash on *another* collateral, governance not re-pointing within the window). Medium.

## Corrections to the finding text (bullet list, or "none")
- Title/impact "every tranche's redemption": only the stale tranche **and every tranche senior to it** are blocked; tranches junior to it still redeem (`lockedValue` breaks at the asking tranche). The PoC stales the junior-most tranche, which is the worst case and blocks all.
- "Escape hatch: ADMIN can `setTranches` without the affected tranche": **wrong in the scenario described**. `_setTranches` ends with `if (healthiness() < 1e27) revert Unhealthy()`, so once the priced collateral has crashed (step 2, health 0.6) the hatch reverts. It only works while the market is still healthy. The working hatch is ADMIN `Oracle.setSource`/`setBackup` (role 0, no delay) to a replacement adapter — worth stating, as it is the actual mitigation.
- Step 3 "Debt keeps accruing premium … against collateral nobody can seize": true but quantitatively negligible (0.055 % of debt per day at 20 % APR; at health 1.05 the market is still not liquidatable after 24 h). The loss is the crash on the priced collateral during the window, not the accrual. Suggest replacing the accrual argument with the concrete comparison above: 49.6 cUSD avoidable bad debt plus the underwriters' entire residual on a 30 % crash of a 500-debt market.
- Recommendation "treat a tranche whose price is unavailable as zero capital" is dangerous as stated and must not be adopted without the grace window the finding mentions as "second-order": zero-valuing the **senior** tranche on a transient blip makes `recoverableDebt` ≈ 0, so `unrecoverableDebt` ≈ whole debt and GUARDIAN `writeOff` could write off the entire loan as bad debt, and `maxLiquidatable` would let a liquidator take the 2 % bonus against a healthy market. The fix should at minimum keep `writeOff` fail-closed and gate any zero-valuation behind a grace period.
- Likelihood paragraph should note that production deploy scripts never set a backup feed (`setBackup` unused outside `Oracle.sol`), so "primary and backup" both stale is only a precondition where governance has configured one.

## Residual doubt (what would settle it if still uncertain)
- Whether governance intends to configure backups for every tranche asset and to hold an emergency adapter ready. If the deployment runbook mandates both, likelihood drops further and a Low/Medium boundary argument opens; if neither, the precondition is a single Chainlink feed going stale, which is a routine event on long-tail assets and would push toward High.
- Whether ADMIN in production sits behind a timelock that the AccessManager role table does not show (grants here are delay 0). A 24–48 h timelock on `setSource` would remove the only working remedy during a crash and would justify High.
