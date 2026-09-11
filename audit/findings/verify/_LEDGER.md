# Verification ledger (Phase 3)

| ID | Claimed | Verdict | Final | One-line reason |
|---|---|---|---|---|
| MED-MULTIPLIER-INERT | Medium | DEMOTE | **Low** | Real (fuzz-confirmed), but a non-functional knob defaulting to 1x; nothing extractable |
| CRIT-ORACLE-DECIMALS | Critical | CONFIRMED | **Critical** | No 18-dec oracle exists anywhere; verifier's own no-price-move test pays LIQUIDATOR 7.87 WETH for 1.5e-6 cUSD. Corrections: accrual-only trigger ~3y (≥38% drawdown is immediate); loss ≈79% unless maxLiquidatable hits the cap |
| HIGH-STALE-MARK | High | CONFIRMED | **High** | One-directional staleness (NAV only falls between marks); bound = idle·L/A_stale cumulative; no role needed. Corrections: 1-wei deposit re-marks the default tranche; attacker = any share holder |
| MED-EMA-MANIPULATION | Medium | CONFIRMED | **Medium** | Figures recomputed independently; park needs no role; borrower is the threat model. Corrections: discount bounded by slope portion (rate floors at base); capital ≈ supply; slopes are test-deployer values |
| MED-RECOGNITION-LAG (G) | Medium | pending | — | Par exits while unrecoverableDebt>0 but badDebt==0 (before discretionary writeOff) shift the shortfall to survivors |
| MED-JIT-PREMIUM | Medium | CONFIRMED | **Medium** | 6h vest is a smoothing knob, not exposure attribution; whole window exploitable (no front-run needed); ~120x honest 6h yield. Corrections: Underwriter-path depositor cannot self-exit (maxRedeem=0); epoch-restart point belongs to C8 |
| MED-PHANTOM-YIELD (D2) | Medium | DEMOTE | **Low** | totalAssets identical with/without rolls: pure share dilution (~0.08%/day of unrecoverable slice) needing KEEPER rolling + GUARDIAN/LIQUIDATOR inaction; documented trade-off. "$327 cashed ahead" refuted. Do NOT auto-recognise in _chargePremium (oracle-wick griefing). Note: writeOff alone is not a full brake — residual at recoverableDebt re-creates shortfall on next roll |
| HIGH-QUEUE-OUT-OF-ORDER (B-1) | High | pending | — | settledQueue high-water mark lets an earlier request claim after unlockedSupply fell to 0; queued claim pushes a healthy market liquidatable |
| MED-STALE-FEED-BRICKS | Medium | CONFIRMED | **Medium** | Matched-path test: outage leaves senior wiped + 49.6 cUSD avoidable bad debt vs 0 with live feeds. Correction: `setTranches` escape hatch reverts Unhealthy() when needed; only remedy is ADMIN re-pointing the feed (role 0, no delay) |
| MED-LOAN-ID-REUSE (D9) | Medium | CONFIRMED | **Medium** | Role-isolated repro: owner/keeper + borrower; 95% premium avoided at $10M, repeatable monthly; I3 exact so pure underpayment of stcUSD/tranches. Defeats minimumMarketMultiplier guard |
| MED-RECOGNITION-LAG (G) | Medium | CONFIRMED | **Medium** | Foundry repro to the wei; roleless; structural lag (write-off is irreversible forgiveness, guardian rationally waits; bot is a block ahead regardless). STRIKE recommendations: permissionless writeOff (oracle-dip windfall) and provisional-shortfall pricing (no place to retire the haircut) |
| HIGH-QUEUE-OUT-OF-ORDER (B-1) | High | CONFIRMED | **High** | Reproduced without the PoC's shortcut: both requests made while locked, unlocked by ordinary repay, re-locked by price at the buffer floor; earlier claim pays 200e18 through the lock, LIQUIDATOR then slashes 69% of the remaining holder. Corrections: "exploit path B" attacker-profit framing is wrong (dominated by instant exit); realistic vector is the organic slow claimant (Underwriter's keeper-finalized deallocateAsync); borrow alone only re-locks a junior queue |

## Final
Critical 1 · High 2 · Medium 5 · demoted to Low 2 · cut 0
