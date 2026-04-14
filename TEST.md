## Testing guide

This repo uses **Foundry** (`forge test`) for Solidity tests under `test/`.

Many “integration-style” suites deploy a full CAP environment via `test/deploy/TestDeployer.sol`, which is driven by a JSON harness config (`config/test-harness.json`) and can run in either:

- **Mock mode** (hermetic, no RPC; faster)
- **Fork mode** (mainnet fork; exercises more real-world wiring)

### Prerequisites

- **Foundry** installed (`forge`, `cast`, `anvil`).
- **Node 20** (see `package.json` engines) and **yarn**.

Install JS deps (provides `node_modules/` imports and generates remappings):

```bash
yarn install
```

### Quick start (most common)

Run all tests:

```bash
forge test
```

Run all tests via package script:

```bash
yarn test
```

### Running targeted tests

Run a folder or file (quote globs so your shell doesn’t expand them into multiple arguments):

```bash
forge test --match-path "test/vault/*.t.sol"
forge test --match-path "test/vault/Vault.mint.t.sol"
```

Run a specific test function or contract:

```bash
forge test --match-test "test_vault_mint"
forge test --match-contract "VaultMintTest"
```

Increase verbosity / traces:

```bash
forge test -vvv
```

### Invariant suites

Run only invariants:

```bash
forge test --match-path "test/**/*.invariants.t.sol"
```

Use the “deep” profile (more runs / higher confidence, slower):

```bash
FOUNDRY_PROFILE=deep forge test --match-path "test/**/*.invariants.t.sol"
```

#### Global invariant settings (`foundry.toml`)

- **`fail_on_revert = true`** — any handler call that reverts causes the test to fail immediately with the revert error. Handler functions must therefore be written defensively (guard invalid inputs before calling contract functions, not just catch-and-continue).
- **`dictionary_weight = 80`** — biases fuzzing toward values already seen in storage, increasing the chance of finding meaningful state interactions.

#### `test/lendingPool/Lender.invariants.t.sol`

| Invariant | What it checks |
|---|---|
| `invariant_agentDelegationLimitsDebt` | Each agent's total debt across all assets (in USD) must never exceed their total delegation (coverage) reported by the Delegation contract. |
| `invariant_debtTokenSupplyEqualsAgentBalances` | The total supply of each asset's debt token must equal the sum of all test-agent debt balances for that asset. |
| `invariant_healthFactorConsistency` | Any agent for whom `maxLiquidatable > 0` on any asset must have `health < 1e27` (i.e., below 1.0 in ray). |
| `invariant_healthyAgentsNotLiquidatable` | Any agent with `health >= 1e27` (healthy) must have `maxLiquidatable == 0` for every asset. Inverse of the above. |

> **Note**: `lender.agent()` internally calls `Delegation.coverage()` which calls the network middleware. Agents that have never borrowed are unregistered in the Delegation contract (`network == address(0)`) and would cause a revert. Both health invariants pre-check debt via `lender.debt()` (a safe storage read) and skip zero-debt agents.

#### `test/vault/Vault.invariants.t.sol`

| Invariant | What it checks |
|---|---|
| `invariant_totalAssetsExceedBorrowed` | `totalSupplies(asset) >= totalBorrows(asset)` for every asset — the vault can never owe more than it has received. |
| `invariant_physicalBalanceGeAvailable` | The vault's physical token balance must be `>= availableBalance(asset)` — physical holdings cover the reported available liquidity. |
| `invariant_totalSuppliesCoversAllAllocations` | `physical + totalBorrows + loaned >= totalSupplies` for every asset — no value is destroyed. Donations increase physical without touching `totalSupplies`, so the direction is "allocations cover deposits", not the reverse. |
| `invariant_mintingIncreaseBalance` | Minting cap tokens increases the vault's asset balance by exactly the minted amount. |
| `invariant_burningDecreasesCapTokenSupply` | Burning cap tokens strictly decreases the total cap token supply. |

#### `test/vault/FractionalReserve.invariants.t.sol`

| Invariant | What it checks |
|---|---|
| `invariant_reserveLimits` | The current held reserve never exceeds the configured reserve target. |
| `invariant_totalAssetsBalance` | `invested + reserve == total assets` — all assets are accounted for between the FR vault and the reserve. |
| `invariant_interestAccuracy` | `claimableInterest` correctly reflects actual FR vault yield above the loaned principal. |
| `invariant_divestingPossible` | Divesting up to the invested amount is always possible without underflow. |
| `invariant_loanedLeInvestedBalance` | The FR vault's redeemable balance is always `>= vault.loaned()` — yield is never negative (principal is always recoverable). |

## Harness configuration (fork vs mock)

### Where config comes from

`TestDeployer` loads a `TestHarnessConfig` using `test/deploy/utils/TestHarnessConfigReader.sol`.

- **Default config file**: `config/test-harness.json`
- **Override env var**: `CAP_TEST_HARNESS_CONFIG`

The config is **keyed by chain id**, and the harness is loaded with:

- `chainId = block.chainid` at the moment `_deployCapTestEnvironment()` first runs

In the committed `config/test-harness.json` you’ll typically see:

- **`"1"`**: fork-backed settings (needs a working `fork.rpcUrl`)
- **`"11155111"`**: mock-backed settings (no RPC required)

### Important: filesystem permissions

Foundry file reads are permissioned via `foundry.toml` `fs_permissions`.

To use a custom harness file, put it under `./config/` (recommended), e.g.:

```bash
export CAP_TEST_HARNESS_CONFIG="config/test-harness.local.json"
forge test
```

### Config fields you typically edit

In `config/test-harness.json`, per chain id key (e.g. `"1"`, `"11155111"`):

- **fork**
  - `useMockBackingNetwork`:
    - `true`: do not fork; use mocked “backing network” components
    - `false`: create a fork using `rpcUrl` (+ optional `blockNumber`)
  - `mockChainId`: chain id to force when mock mode is enabled
  - `rpcUrl`: fork RPC endpoint (only used when `useMockBackingNetwork=false`)
  - `blockNumber`: fork block; use `0` for “latest”
- **infra**
  - `delegationEpochDuration`: epoch duration used by delegation-related tests
- **oracle**
  - price/rate seed values used by oracle-backed calculations
- **fee**
  - parameters used when wiring fee logic in tests
- **symbiotic / eigen / scenario**
  - parameters used for provider + scenario setup

### Choosing mock mode locally (recommended for CI-like runs)

If your local test chain id is not present in the JSON, the harness falls back to defaults (which may select **fork mode**).

To force mock mode reliably in your environment, add a local harness entry for your chain id (commonly `31337`) in a custom file under `config/`, then point `CAP_TEST_HARNESS_CONFIG` at it.

Example shape (values are illustrative; keep the structure the same):

```json
{
  "31337": {
    "fork": { "useMockBackingNetwork": true, "mockChainId": 11155111, "rpcUrl": "", "blockNumber": 0 },
    "infra": { "delegationEpochDuration": 86400 },
    "oracle": {
      "usdPrice8": 100000000,
      "usdRateRay": 100000000000000000000000000,
      "ethPrice8": 260000000000,
      "ethRateRay": 100000000000000000000000000,
      "permissionedPrice8": 100000000,
      "permissionedRateRay": 100000000000000000000000000,
      "extraChainlinkAsset": "0x0000000000000000000000000000000000000000"
    },
    "fee": { "minMintFee": 5000000000000000000000000, "slope0": 0, "slope1": 0, "mintKinkRatio": 850000000000000000000000000, "burnKinkRatio": 150000000000000000000000000, "optimalRatio": 330000000000000000000000000 },
    "symbiotic": { "vaultEpochDuration": 604800, "feeAllowed": 1000, "defaultAgentLtvRay": 500000000000000000000000000, "defaultAgentLiquidationThresholdRay": 700000000000000000000000000, "defaultDelegationRateRay": 20000000000000000000000000, "defaultCoverageCapUsd8": 100000000000000000000, "mockAgentCoverageUsd8": 100000000000000 },
    "eigen": { "rewardDuration": 7, "delegationAmountNoDecimals": 10 },
    "scenario": { "postDeployTimeSkip": 2419200 }
  }
}
```

Then:

```bash
export CAP_TEST_HARNESS_CONFIG="config/test-harness.local.json"
forge test
```

### Choosing fork mode

To run against a fork, set `useMockBackingNetwork=false` and provide a valid `rpcUrl` (and optionally `blockNumber`) in the harness JSON for the chain id being loaded.

## Manual test scratchpads

`test/manual/*.manual.sol` contains **non-CI scratchpads** for experimentation (typically on a fork).
They intentionally contain **no `test*` functions**, so they will never run as part of `forge test`.

## Troubleshooting

### “unexpected argument …” when using `--match-path`

Quote the path/glob so your shell doesn’t expand it:

```bash
forge test --match-path "test/oracle/*.t.sol"
```

### Foundry warns about unknown keys in `foundry.toml`

You may see warnings (especially on nightly builds). Tests should still run; treat them as configuration lint rather than test failures.

