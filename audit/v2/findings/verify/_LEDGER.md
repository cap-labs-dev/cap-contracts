# Round-2 verification ledger

| ID | Claimed | Verdict | Final | Reason |
|---|---|---|---|---|
| R2-HIGH-AERA-LOSS (N2) | High | CONFIRMED | **High** | No path to book a known reserve loss; uncapped invest; lands 100% on last redeemers while maxRedeem advertises par. Residual: likelihood depends on the real vault config |
| R2-MED-INVEST-LIQUIDITY (N2) | Medium | DEMOTE | **Low** | KEEPER-only; reverted claim keeps queue position and settles after recall or any fresh deposit; no loss. (Verifier wrongly said Wrapper does not exist — it does, but never calls maxRedeem.) |
| R2-MED-WRAPPER-INFLATION (N1) | Medium | CONFIRMED | **Medium** | Attacker nets V/2 with 1 wei; post-exit permanent zero-share trap; no seed enforced. Demotes to Low if deploy seeds ≥1e18 |
| R2-MED-CIRCUIT-BREAKER (R2/L-15, N4) | Medium (raised) | DEMOTE | **Low** | Regression real, but all 10 mainnet feeds checked publish no clamp (min=1, max=2^176−1); same governance+crash precondition as round 1. L2 feeds unverified |
| R2-HIGH-CURATOR-DRAIN (N3-1) | High | CONFIRMED | **High** | 100% TVL on production wiring; regression against the v1 comment that held addTranche above the curator. Corrections: stubbed fake is removable; role revoke does not clear Vault operator flag |
| R2-MED-OWNER-SETTRANCHES (N3-2) | Medium | CONFIRMED | **Medium** | Membership AND order of the slash loop are owner-controlled; first-loss layer voidable; irreversible by any role. Corrections: 20→80% overstates (54% reachable before); owner≠borrower suffices |

## Final (round 2)
High 2 · Medium 2 · demoted to Low 2 · cut 0 (plus round-1 H-1/H-2/M-1..M-5 re-confirmed open by R1)
