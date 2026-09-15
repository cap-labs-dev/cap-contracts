# Lead auditor findings (independent of workstreams)

### [CRITICAL] Oracle answers in 8 decimals but Tranche and markets consume the price as 18 decimals — every USD figure in the credit system is 1e10x off with the production oracle
**Location:** contracts/cap/oracle/Oracle.sol:L16-L18 (`DECIMALS = 8`, `ONE = 10**8`), contracts/cap/oracle/ChainlinkAdapter.sol:L57-L61 (normalises to 8), contracts/cap/Tranche.sol:L281-L288 (`totalCapital`, `activeCapital`), L83-L89 (`slash`), L274 (`unlockedSupply`); contracts/interfaces/ITranche.sol:L22,L59,L61,L153,L157 (documents USD **18** decimals)
**Impact:** With the repo's own `Oracle` wired (the only oracle implementation in scope, and the one `Registry._deployTranche` liveness-checks against), `Tranche.totalCapital()` for 1000 ETH at $2,000 is `2e14`, not `2e24`. `BaseMarket.healthiness`, `creditLimit`, `variableCreditLimit`, `recoverableDebt`, `maxLiquidatable`, `lockedValue` all compare that 8-dec capital against 18-dec cUSD debt. Consequences: (a) borrowing is capped at ~1e-10 of the intended limit (fail-closed, protocol non-functional); (b) `Tranche.slash` converts an 18-dec USD `value` at an 8-dec price → asset amount 1e10x too large → clamped to `totalAssets` → **the whole tranche is seized for dust of cUSD**; (c) `Tranche.unlockedSupply` locks 1e10x too many shares → every underwriter is locked out of redemption while any debt exists.
**Likelihood:** Certain on deployment with `Oracle.sol`. No attacker needed for (a)/(c). For (b): the dust borrow that IS permitted, plus any health dip, lets the LIQUIDATOR (or anyone if the role is ever opened) take a $2M tranche for ~0.0002 cUSD.
**Exploit path:** see WS-E PoC (assigned) for the full seize path. Reproduction of the scale error: `audit/tests/scratch/LEAD/OracleDecimals.t.sol`.
**Proof:**
```
[FAIL: totalCapital should be $2,000,000 in 18 decimals: 200000000000000 != 2000000000000000000000000] test_realOracle_trancheCapital_isTenOrdersOfMagnitudeOff()
Logs:
  totalCapital reported: 200000000000000
  expected USD 18-dec  : 2000000000000000000000000
```
**Recommendation:** Pick one scale and enforce it at the boundary. Either have `Tranche.getPrice()` rescale by `10**(18 - IOracle(oracle).DECIMALS())`, or make `Oracle.DECIMALS = 18` and rescale in `ChainlinkAdapter`. Then fix `test/shared/mocks/MockOracle.sol`, which declares `DECIMALS = 8` while every integration test feeds it `1e18` — the mock disagreeing with the real oracle is why 399 passing tests never saw this. Add one integration test that wires the real `Oracle` + `ChainlinkAdapter` through a market.
**Invariant broken:** I5 (coverage), I8, I12 (slash over-withdraws relative to debt cleared) — and the core promise: depositor/underwriter protection is enforced against a number that is wrong by ten orders of magnitude.
