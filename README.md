# CAP Network Contracts

CAP is a stablecoin and credit protocol. It issues **cUSD** against reserve-token deposits and credit extended to permissioned borrowers. Collateral providers supply capital to market tranches that back this credit and earn borrower premiums. **stcUSD** wraps cUSD in a vault that incorporates vested premiums into its share value.

This repository contains the Solidity contracts, deployment tooling, and Foundry unit, integration, fuzz, and invariant tests.

## How the protocol works

- **Stablecoin liquidity:** users deposit the configured reserve token to mint cUSD at par, adjusted for token decimals. Markets can also mint credit-backed cUSD when an authorized borrower draws credit. Repayments burn cUSD and reduce outstanding credit.
- **Collateral and tranches:** the `Vault` holds collateral ERC20s and represents them as ERC6909 balances. Providers deposit those balances into `Tranche` contracts. Tranche capital, oracle prices, and market risk limits determine borrowing capacity. Liquidations consume junior collateral before senior collateral; providers can lose deposited capital.
- **Credit markets:** `FloatingMarket` accrues premiums through debt indexes. `FixedMarket` records individual loans with a term and premiums charged on borrowing or extension. Both use shared credit limits, health checks, liquidation, and bad-debt accounting.
- **Underwriter pools:** an `Underwriter` pools provider capital, allocates it across registered tranches, and distributes their premiums. Position values are cached and refreshed through allocation, deallocation, and reporting operations.
- **Premiums:** borrower premiums fund cUSD holders and eligible tranches. Holders of cUSD, tranche shares, and underwriter shares opt in to earn vested premiums and claim them in cUSD. The `Wrapper` opts in on behalf of stcUSD holders and includes claimable premiums in its assets.
- **Exits:** cUSD, tranches, and underwriter pools support queued redemptions and instant exits when liquidity and credit constraints permit. Recognized losses can affect exit value. Redeeming stcUSD returns cUSD; redeeming cUSD returns the reserve token.
- **Configuration and access:** `Registry` creates markets and underwriter pools and wires their roles through OpenZeppelin `AccessManager`. `Oracle` prices collateral, and `InterestRateModel` supplies rate calculations. Markets, tranches, and underwriter pools use beacon proxies; core infrastructure contracts use UUPS proxies.

Core implementations are in [contracts/cap](contracts/cap), public interfaces in [contracts/interfaces](contracts/interfaces), and premium accounting in [PremiumVesting.sol](contracts/utils/PremiumVesting.sol).

### Write-offs and market health

A guardian can write off derived unrecoverable debt while a market is unhealthy. A write-off reduces market debt and credit-backed cUSD supply and increases recognized cUSD bad debt, without slashing collateral or adding reserves. The remaining debt may be healthy: the health requirement applies before the write-off, and continued liquidatability is not guaranteed. Liquidation is blocked while the remaining market debt is healthy.

Ignoring integer rounding, a full floating-market write-off with nonzero remaining debt leaves debt at `capital / (1 + liquidationBonus)` and health at `LT × (1 + liquidationBonus)`, with ratios expressed as fractions. With a 2% liquidation bonus, the remaining debt can be healthy at an LT of approximately 98.0392% or higher. The buffer affects collateral locking and LTV validation, but does not enter the health or recoverable-debt calculation.

The buffer must be at least 10% (`0.1e27`) and strictly below LT, both at initialization and when changed. Credit capacity uses `min(LTV, LT - buffer)`, so increasing the buffer or lowering LT tightens the effective borrowing limit even if the stored LTV is higher. With LT capped at 100%, credit capacity is at most 90% of eligible collateral. Even at the maximum 10% liquidation bonus, a full write-off leaves approximately 90.91% of total collateral value as debt, preventing the write-off from immediately reopening borrowing capacity against the same collateral.

Write-offs do not permanently pause borrowing; later repayments or collateral changes may create available credit. A healthy state after a write-off does not mean the recognized loss has been covered or new reserves have arrived. Upgrades do not rewrite previously stored buffers, so existing deployments with buffers below 10% require a configuration update before relying on this bound.

## Development setup

Required: Git, Node.js **24.12.x**, Yarn **1.22.22**, and Foundry **v1.5.1**. Install Foundry with [foundryup](https://getfoundry.sh/). The checked-in configuration uses Solidity **0.8.36** and the **Osaka** EVM target.

Run from the repository root:

```sh
foundryup --install v1.5.1
npm install --global yarn@1.22.22
git submodule update --init --recursive
yarn install --frozen-lockfile
forge --version
```

`yarn install` also installs Git hooks and writes `remappings.txt`. CI uses `--ignore-scripts` to skip those local setup steps.

### Build and test

```sh
yarn compile                        # Build with the default Foundry configuration
yarn build                          # Build with the package's --skip Test filter
yarn test                           # Run the default test suite
forge test --match-contract DebtLifecycleTest -vvv
forge fmt --check                   # Check Solidity formatting

# Full suite with explicit fuzz/invariant budgets and saved metrics
bash script/run-fuzz-tests.sh local  # 256 fuzz runs; 32 invariant sequences, depth 64
bash script/run-fuzz-tests.sh pr     # 1,000 fuzz runs; 256 sequences, depth 128
bash script/run-fuzz-tests.sh deep   # 10,000 fuzz runs; 2,048 sequences, depth 256

# Reproduce a seed, or run only the new fuzz/invariant tests
FOUNDRY_FUZZ_SEED=0xcafef00d bash script/run-fuzz-tests.sh pr
bash script/run-fuzz-tests.sh local --match-path 'test/invariant/*'
```

Invariant budgets apply per campaign. Logs, seeds, source hashes, and metrics are written to `artifacts/fuzz-and-invariant-tests/`. See the [fuzz and invariant guide](test/invariant/README.md) for properties, assumptions, profiles, and reproduction instructions.

Local protocol tests deploy their own fixtures. Migration tests require `ETH_RPC_URL` and skip when it is unset:

```sh
ETH_RPC_URL='<Ethereum RPC URL>' forge test --match-path 'test/migration/*' -vvv
```

### Coverage and analysis

```sh
yarn test:build             # Compile contracts, tests, and scripts with --via-ir
yarn coverage:forge         # Coverage summary
yarn coverage:forge:report  # LCOV and HTML report in coverage/
yarn test:slither           # Slither analysis
```

The HTML report requires `lcov`/`genhtml`; static analysis requires [Slither](https://github.com/crytic/slither).

## Interact with a deployed protocol

Addresses for a chain are in [config/cap-v2.json](config/cap-v2.json). See [config/README.md](config/README.md) for the layout. Zero addresses are undeployed. Market, tranche, and underwriter instances come from Registry creation events, not that file.

```sh
cast wallet import cap-operator --interactive

export RPC_URL='<target-chain RPC URL>'
export ACCOUNT='cap-operator'
export USER_ADDRESS='<address of that account>'
export CUSD='<infra.stablecoin>'
export RESERVE_TOKEN='<stablecoinUnderlying>'
```

Amounts are integers in smallest units. cUSD and debt use **18 decimals**; reserve and collateral use the token's decimals. Health and rate ratios use **27 decimals** (`1e27` is 1).

`cast call` reads state; `cast send` submits a transaction with a Foundry keystore account. Signatures are in [contracts/interfaces](contracts/interfaces); role IDs are in [CapRoles.sol](contracts/utils/CapRoles.sol).

```sh
cast call "$CUSD" 'balanceOf(address)(uint256)' "$USER_ADDRESS" --rpc-url "$RPC_URL"
cast send "$RESERVE_TOKEN" 'approve(address,uint256)' "$CUSD" "$ASSETS" --rpc-url "$RPC_URL" --account "$ACCOUNT"
cast send "$CUSD" 'deposit(uint256,address)' "$ASSETS" "$USER_ADDRESS" --rpc-url "$RPC_URL" --account "$ACCOUNT"
yarn check-roles --rpc-url "$RPC_URL"
```

A few protocol-specific notes:

- Tranche and underwriter deposits pull **Vault balances**. Approve the ERC20 to the Vault, call `Vault.deposit`, then `setOperator` before depositing. Withdrawals return Vault balances.
- Market repayment burns the caller's cUSD and does not need an ERC20 approval. Pass `cast max-uint` to clear remaining premium debt.
- Queue an exit with `requestRedeem`, then `redeem` the claimable amount. Instant exits stay within `maxInstantRedeem`. Async `previewRedeem` and `previewWithdraw` are unsupported.
- Call `optIn` and `claim` on cUSD, tranche, or underwriter shares. The wrapper opts in for stcUSD holders.

## Deploy infrastructure

[Deploy.s.sol](script/Deploy.s.sol) deploys fresh shared infrastructure through CreateX, initializes access control, seeds the wrapper, and writes the result to `config/cap-v2.json`. It does not create or configure individual credit markets. The target chain needs the canonical CreateX factory and support for the configured EVM bytecode.

Before running it:

- Add the target chain's entry to `config/cap-v2.json`, using the existing schema. Keep its deployer and token fields aligned with the environment; the serializer preserves those fields.
- Set `STABLECOIN_UNDERLYING`. Optionally set `RESERVE_VAULT` and a bytes32 `SALT_NAMESPACE` for a distinct deterministic deployment.
- Set `ADMIN`, `GOVERNOR`, `KEEPER`, `GUARDIAN`, and `LIQUIDATOR` as needed. Unset role addresses default to the broadcast sender. The role checker expects the deployer's admin role to be removed, so use a separate `ADMIN` for that handoff.
- Fund the sender with gas and enough reserve tokens to seed one cUSD of permanent wrapper shares.

```sh
export STABLECOIN_UNDERLYING="$RESERVE_TOKEN"
export ADMIN='<admin address distinct from the deployer>'

# Simulate with an explicit sender; this also writes the local address config
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --sender "$USER_ADDRESS"

# Broadcast the deployment with the same sender and configuration
yarn deploy --rpc-url "$RPC_URL" --sender "$USER_ADDRESS" --account "$ACCOUNT"

yarn check-roles --rpc-url "$RPC_URL"
```

After deployment, configure oracle sources, market creation permissions, market rates/risk parameters, and participant roles through `Registry`, `Oracle`, and `AccessManager` before opening credit. Migration helpers for existing cUSD/stcUSD proxies live in [script/deploy/service/MigrateInfra.sol](script/deploy/service/MigrateInfra.sol); the fresh deployment command is not an upgrade procedure.

## Repository layout

- [contracts/cap](contracts/cap): stablecoin, collateral custody, markets, tranches, underwriters, registry, rates, and oracle.
- [contracts/ERC7540](contracts/ERC7540): queued redemption and operator accounting.
- [contracts/utils](contracts/utils): premium vesting, role IDs, asset IDs, and arithmetic.
- [script](script): deployment, role inspection, and fuzz/invariant runners.
- [config](config): chain-specific infrastructure addresses; older configuration is under `archive/`.
- [test](test): unit, integration, migration, and numerical/stateful property tests.

Generated build output, coverage reports, campaign artifacts, and Foundry failure caches are ignored by Git. Preserve minimized counterexamples and turn confirmed failures into regression tests.