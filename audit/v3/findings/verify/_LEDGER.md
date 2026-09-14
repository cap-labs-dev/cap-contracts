# Verification ledger — round 3 (one fresh subagent per new C/H/M, code + finding text only)

| ID (WS) | Filed | Verdict | Final | Report ID | Key correction |
|---|---|---|---|---|---|
| U-1 (U) | Critical | CONFIRMED-AT-LOWER | **High** (Critical if executed as a bare upgrade) | R3-H1 | A two-step upgrade via an out-of-tree migrator recovers both proxies (v1 `_authorizeUpgrade` accepts any impl); "permanent" holds only after a bare upgrade. stcUSD's ERC4626 namespace survives (`asset()==cUSD`). |
| U-2 (U) | Critical | CONFIRMED-AT-LOWER | **High**, merged into R3-H1 | R3-H1 | `canCallWithDelay` on `address(0)` returns unauthorized (never "allowed"); irreversibility clause of U-1, not a separate finding. |
| U-3 (U) | High | CONFIRMED-AT-LOWER | **Medium**, merged into R3-H1 | R3-M6 | "Forever" holds only after a bare upgrade; the migrator path calls `optIn`; the frozen premium vests after repair; the 11,335 step is a v1 profit-snapshot artefact. Silent failure → fork test must assert `optedIn(stcUSD)`. |
| U-4 (U) | High | CONFIRMED-AT-LOWER | **Low**, migration checklist | U-4 | `totalAssets() > on hand` is documented HEAD design; a follow-up impl sweeps FR shares/wWTGXX; loan repayments need no entry point. Remaining: v1 loans unrepresentable, par-FIFO until reserve arrives, wWTGXX re-denomination. |
| C-2 (C) | High | CONFIRMED | **High** | R3-H3 | Entry-leg loss is bounded by the slash amount `L` and single-victim when a default tranche is set; "not bounded by idle" is true but "unbounded" is not. |
| D-1 (D) | Medium | CONFIRMED | **Medium** | R3-M1 | Precondition is a *staked* dead tranche; stakers' `optOut()` restores `repay`/`chargePremium` only; drop the 0.816 figure. |
| D-2 (D) | Medium | CONFIRMED-AT-LOWER | **Low** | D-2 | Protocol-trusted misconfiguration (`lt·(1+b) > 1`); loss ≤ 1.96 % of collateral at the deploy bonus; "3.5 % of supply" was padded. |
| D-3 (D) | Medium | CONFIRMED-AT-LOWER | **Low** | D-3 | GUARDIAN `setBuffer(0)`+`setLt(1)` is an immediate on-chain remedy; the keeper path never fully clears (health-targeted `maxLiquidatable`); borrower gains nothing the fix would remove. |
| LEAD-1 (lead) | Medium | CONFIRMED-AT-LOWER | **Low** | LEAD-1 | Junior-locks-first is the documented model with a repo test asserting it; USD coverage unchanged at the swap; events do fire; "GOVERNOR sized against WETH" is not a contract fact. Merge with C-9. |
| LEAD-2 (lead) | Medium | CONFIRMED | **Medium** | R3-M2 | +13.8 % splits 61.5 % EMA-bypass / 38.5 % catch-up; surplus to stcUSD stakers only; a 12-s hold suffices (no bundle); dropping the same-timestamp early return is ineffective; corollary: `availableCredit(term)` shrinks (DoS on pre-sized draws). |
| B-1 (B) | Medium | CONFIRMED | **Medium** (low end) | R3-M4 | Victim recovery is batchable (300 ids in one tx at 29 % of attacker cost); depositor role irrelevant (share transfers ungated); Medium carried by integrators with no `transferRequest`/4-arg path. |
| LEAD-3 (lead) | Medium | CONFIRMED-AT-LOWER | **Low** | LEAD-3 | Sibling of L-21; ~1.0 % APR forgone at the reference; weight 1 wei pays 0 so a bps floor is the fix. |
| G-1 (G) | Medium | CONFIRMED | **Medium** | R3-M5 | On-chain +$437 k on a $5M loan (model's +$257 k was conservative); at launch $1M captures $10.55M; carry flips negative above φ*; the reserve-backed-denominator fix is insufficient — cap per-share vest at `r(u)`. `r = 0` until slopes are set. |

Carried findings (H-1, R2-H1, M-1, M-2, M-3, M-4, R2-H2 and all Lows) were re-verified by WS-R with ported tests rather than by a fresh disprover: `findings/REGRESSION.md`.
