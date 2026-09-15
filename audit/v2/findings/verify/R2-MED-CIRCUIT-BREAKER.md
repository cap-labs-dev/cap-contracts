# R2-MED-CIRCUIT-BREAKER — L-15 raised to Medium (R2 §4, N4 [MEDIUM])

## Verdict: DEMOTE to Low

## Why
The code regression is real and the PoC is honest (`ChainlinkAdapter.price` now rejects only `answer <= 0`; a clamped, freshly-stamped answer is served and the secondary is never consulted because the answer is non-zero), but the *likelihood* leg of the Medium case rests on a premise that is false on the chain the protocol targets: every mainnet Chainlink feed I read at block 25,954,033 — ETH/USD, BTC/USD, USDC/USD, USDT/USD, DAI/USD, stETH/USD, stETH/ETH, LINK/USD, cbETH/ETH, rETH/ETH — publishes `minAnswer = 1` and `maxAnswer = 2^176 − 1 (9.578e52)`, i.e. no clamp at all. The deleted `_withinBounds` would never have fired on any of these feeds, so the deletion removes a defence that had no live surface; the exploit still needs governance to list a collateral whose aggregator carries a real floor (none found on Ethereum) AND a crash through that floor. That is the same "governance misconfiguration + rare market event" precondition round 1 scored Low, and the removal of the proxy-hop caveat does not change the probability of the event. Impact if it did happen is unchanged from round 1 (`over-borrow = ltv·C·(f−1)`, `liquidate` reverts `Healthy()` at `BaseMarket.sol:314`), so impact x likelihood stays Low.

## What I tried
1. Read `contracts/cap/oracle/ChainlinkAdapter.sol` (library, 31 lines: `answer <= 0 → (0, lastUpdated)`, then decimals scaling), `contracts/cap/oracle/Oracle.sol` (`_fetchPrice` falls to secondary only on `latestAnswer == 0`; `_read` zeroes only on stale) and `git diff 3c45dca..3dad5ef -- contracts/cap/oracle/ChainlinkAdapter.sol` — `_withinBounds`, `AtCircuitBreaker`, `IncompleteRound` and `NonPositiveAnswer` all removed; the LUNA/Venus NatSpec paragraph removed with them. Confirmed: no bounds check anywhere in `contracts/` (`grep -rni "minAnswer|maxAnswer|circuit" --exclude-dir=lib --exclude-dir=audit .` → only an unrelated comment in `test/integration/Tranche.t.sol:77`).
2. Ran the PoC: `FOUNDRY_TEST=audit/v2/tests/scratch/R2 forge test --match-path 'audit/v2/tests/scratch/R2/oracle/L-15_CircuitBreaker.t.sol' -vv` →
   ```
   [FAIL: an answer resting on the published floor must be refused] test_H4a_floorAcceptedWhenAggregatorHopMissing() (gas: 267923)
     adapter accepted clamped answer: 100000000000000000000
   [FAIL: ... 1000000000000000000 == 1000000000000000000] test_L15_answerOnFloorServedAsLivePrice() (gas: 79091)
     minAnswer (18 dec): 1.000000000000000000
     Oracle.price(asset) observed: 1.000000000000000000
     secondary (true) price: 0.000100000000000000
   ```
   The PoC does not cheat (uses `_deployCap()`, GOVERNOR-gated `setSource` from the deployer, the real library adapter), but it only demonstrates the state — it needs a bespoke `BoundedAggregator` that publishes a `1e8` floor, which is the shape no current mainnet feed has (item 3). It shows no loss by itself; the loss chain is in N4's `test_N8a` (99,999 cUSD drawn against $200 true collateral), which sets the price directly via `_setPrice` and so proves the impact arithmetic, not the likelihood.
3. Checked whether the precedent still exists on live feeds (`cast call <proxy> aggregator()` → `minAnswer()/maxAnswer()` on the aggregator, `ETH_RPC_URL` from `.env`, block 25,954,033):
   ```
   ETH/USD   agg=0x7d4E7420…  min=1 max=95780971304118053647396689196894323976171195136475135 [9.578e52]
   BTC/USD   agg=0x4a3411ac…  min=1 max=9.578e52
   USDC/USD  agg=0xc9E1a096…  min=1 max=9.578e52
   USDT/USD  agg=0x0d5F4aAD…  min=1 max=9.578e52
   DAI/USD   agg=0x709783ab…  min=1 max=9.578e52
   stETH/USD agg=0x26f19680…  min=1 max=9.578e52
   stETH/ETH agg=0xC9c8Efa8…  min=1 max=9.578e52
   LINK/USD  agg=0x96d6e33B…  min=1 max=9.578e52
   cbETH/ETH agg=0x1E726556…  min=1 max=9.578e52
   rETH/ETH  agg=0xc77904CD…  min=1 max=9.578e52
   ```
   10/10 feeds queried have vestigial bounds (`int192` extremes, the post-LUNA Chainlink convention). A `minAnswer = 1` (1e-8 USD) floor cannot be hit by a real crash before `answer <= 0` would; the removed check would have been a no-op on each of them. (wstETH/ETH and wBTC/BTC addresses I tried had no code — those pairs are not standard mainnet feeds, not evidence either way.)
4. Design intent (angle d): the same commit `3dad5ef` ("Refactor premium vesting and natspec") also deleted `aggregator()`, `minAnswer()`, `maxAnswer()` from `contracts/interfaces/IChainlink.sol` and rewrote the adapter NatSpec ("Zero if the answer is not positive"). Three coordinated deletions across two files is a deliberate removal, not an accidental drop during the contract → library conversion; but no commit message, NatSpec or doc records *why*, so the team cannot currently point to a defended rationale.
5. Secondary as mitigation (angle c): confirmed not a mitigation — `_fetchPrice` only consults `secondary` when the primary read is `0`, and a clamp is non-zero and fresh. `IOracle.sol:16` documents the secondary as "used when the primary cannot answer", which a clamped primary does not satisfy. The real in-protocol mitigation is GOVERNOR `setSource` (`Registry.sol:365`) to a different feed, which requires the dry-run to produce a non-zero price (`Oracle.sol:36`), so governance can re-point but cannot blank the chain without freezing `totalCapital` (M-1).
6. Impact chain (angle b): `variableCreditLimit = totalCapital·ltv` (`BaseMarket.sol:275-280`), `totalCapital` = Σ `Tranche.totalCapital` = `totalAssets·price/10^dec` (`Tranche.sol:165`), `liquidate` reverts `Healthy()` while `healthiness ≥ 1e27` (`BaseMarket.sol:314`). Round-1 formula holds: over-borrow `= ltv·C·(f−1)` with `f = floor/true`. For N4's scenario `f = 1000`, so the whole draw is unrecoverable — the impact leg is correct and unchanged from round 1.

## Corrections to the finding text
- R2 §4 "Likelihood: Requires a real collateral crash below the feed floor (rare, but has happened: LUNA, and several stables' floors)" — should add that on current Ethereum mainnet feeds the floor is `1` (1e-8) and the ceiling `2^176−1`; the LUNA-era floors no longer exist on any of the ten blue-chip feeds checked. The precondition is now "governance lists a collateral whose aggregator still carries a meaningful `minAnswer`", which is a configuration event, not a market event.
- N4 [MEDIUM] "most legacy Ethereum/Arbitrum aggregators still carry a non-trivial `minAnswer`" — contradicted for Ethereum by item 3 (10/10 vestigial). Arbitrum not verified; the claim should be dropped or sourced.
- R2 §4 "now there is no check" — accurate; but "Round 1 rated this Low because the check existed" mis-states the round-1 rationale, which was "requires governance to configure a feed without the proxy hop AND the asset to crash through the feed's floor … hence Low" (`audit/findings/E.md:93`). Both halves of that precondition are still required; only the first is now automatically true.
- Recommendation is still worth making (cheap, and the secondary slot exists for exactly this), but frame it as defence-in-depth for non-Ethereum deployments and for any future feed with real bounds, not as restoring a live protection. Ask the team to record the removal rationale in `ChainlinkAdapter` NatSpec.
- Severity block header should read `[LOW, regressed — keep Low]`; N4's [MEDIUM] duplicate should be merged into L-15 at Low.

## Residual doubt
The foundry RPC list targets Monad, Tempo, MegaETH and Katana as well as Ethereum. I only verified Ethereum. If a target chain's Chainlink deployment (or a non-Chainlink feed wrapped to `latestRoundData()`) publishes a real `minAnswer`, and governance lists that asset, the Medium likelihood argument revives for that deployment. Settling it: enumerate the intended collateral list per chain and read `minAnswer/maxAnswer` on each aggregator; any feed where `minAnswer > 0.01·latestAnswer` would move this back to Medium for that market.
