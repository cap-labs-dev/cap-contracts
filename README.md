# CAP Network Contracts

CAP is a stablecoin and credit protocol. It issues **cUSD** against reserve-token deposits and credit extended to permissioned borrowers. Collateral providers supply capital to market tranches that back this credit and earn borrower premiums. **stcUSD** wraps cUSD in a vault that incorporates vested premiums into its share value.

This repository contains the Solidity contracts, deployment tooling, and Foundry unit, integration, fuzz, and invariant tests.

## How the protocol works

- **Stablecoin liquidity:** users deposit the configured reserve token to mint cUSD at par, adjusted for token decimals. Markets can also mint credit-backed cUSD when an authorized borrower draws credit. Repayments burn cUSD and reduce outstanding credit.
- **Collateral and tranches:** the `Vault` holds collateral ERC20s and represents them as ERC6909 balances. Providers deposit those balances into `Tranche` contracts. Tranche capital, oracle prices, and market risk limits determine borrowing capacity. Liquidations consume junior collateral before senior collateral; providers can lose deposited capital.
- **Credit markets:** `FloatingMarket` accrues premiums through debt indexes. `FixedMarket` records individual loans with a term and premiums charged on borrowing or extension. Both use shared credit limits, health checks, liquidation, and bad-debt accounting.
- Each market supports at most **10 configured tranches**, including empty, killed and zero-weight tranches. This is a fixed code limit with no administrative setter, enforced before deployment or premium settlement during tranche configuration.
- **Empty floating markets:** With no scaled debt, debt is zero without evaluating indexes. Index views use a liquidity index of one ray and the current IRM underwriter index. An empty-market premium checkpoint resets the local liquidity index and refreshes both IRM baselines before new borrowing; no premium is minted for the empty interval. The combined index can decrease between debt lifecycles.
- **Underwriter pools:** an `Underwriter` pools provider capital, allocates it across registered tranches, and distributes their premiums. Position values are cached and refreshed through allocation, deallocation, and reporting operations. A position update permanently retires the pool if its recorded assets fall below 1% of par. Retired pools reject new deposits and mints while keeping exits and premium claims open; new capital uses a fresh pool. A killed default tranche also makes `maxDeposit` and `maxMint` return zero until that default is removed or replaced with a live tranche; this does not itself retire an otherwise healthy pool. Deposit and mint quotes use the current value of the default-tranche position, including queued shares and holdings whose recorded debt is zero; other positions keep their cached values. Unreported losses on non-default positions can therefore overcharge new depositors, while unreported gains can dilute existing holders. Keepers should report non-default positions after slashes or other value changes; reporting is an operational mitigation and does not prevent a deposit from arriving first. Integrators should use `previewDeposit` and `previewMint` for issuance quotes: they can differ from the cached `convertToShares` / `convertToAssets` quotes, and with an existing share supply they propagate failures from the default tranche's valuation. Harvested tranche premiums enter the pool's own vesting pot, even though they have already vested at the tranche. They reward opted-in pool balances as the pot vests, so later depositors may earn from premiums generated before they joined. Already-credited pool rewards remain with the holders who earned them. The curator controls the pool's vesting period independently of its tranches through the shared `PremiumVesting.setVestingPeriod` function. This is gradual distribution, not a minimum holding period or a separate vesting clock for each depositor; reporting cadence affects when premiums begin vesting at the pool.
- **Deposit rounding:** Stablecoin, Tranche, Underwriter, and Wrapper deposits and mints must issue nonzero shares. Zero-share executions revert before assets are transferred; previews can still quote zero. This also prevents an Underwriter allocation from donating assets for zero tranche shares. Positive share outputs remain subject to normal rounding.
- **Premiums:** borrower premiums fund cUSD holders and eligible tranches. Holders of cUSD, tranche shares, and underwriter shares opt in to earn vested premiums and claim them in cUSD. The `Wrapper` opts in on behalf of stcUSD holders and includes claimable premiums in its assets. Each contract has a configurable exponential vesting time constant, validated and stored during initialization alongside its access authority. At market creation, fixed-market tranches start at half the maximum term, rounded down to seconds; floating-market tranches, cUSD, and Underwriters start with `Registry.DEFAULT_VESTING_PERIOD` (12 hours), passed through their initializers. When adding a tranche later, the market owner passes its initial vesting period explicitly to `Registry.createTranche`. Changing term limits does not change existing vesting periods. The governor can change the period for cUSD and tranches; the curator can change it for an Underwriter. Changes checkpoint elapsed vesting under the old period before applying the new period to the remaining pot. With continuous opted-in participation and no additional funding, approximately 86.47% of a premium pot vests over two periods. Upgrades of existing deployments require migration of premium-vesting state and configuration of the new setter's intended role in AccessManager.
- **Exits:** cUSD, tranches, and underwriter pools support queued redemptions and instant exits when liquidity and credit constraints permit. Recognized losses can affect exit value. Redeeming stcUSD returns cUSD; redeeming cUSD returns the reserve token.
- **cUSD shortfalls:** exit pricing uses supply excluding performing credit (`totalSupply - creditBackedSupply`), so credit issuance and repayment do not change the haircut for an identical exit. Managed backing (`backing` / `totalAssets`) still includes performing credit. Borrowed and deposited cUSD are fungible: borrowers can redeem against available reserves, absorbing bad debt through the haircut without repaying their loans. Repeated exits can exhaust cash and leave remaining holders backed entirely by credit; the pricing rule does not guarantee a minimum liquid reserve.
- **Configuration and access:** `Registry` creates markets and underwriter pools and wires their roles through OpenZeppelin `AccessManager`. `Oracle` prices collateral, and `InterestRateModel` supplies rate calculations. Markets, tranches, and underwriter pools use beacon proxies; core infrastructure contracts use UUPS proxies.

Floating markets allocate underwriting premium using the liquidity index at the previous realization, then allocate the remaining debt growth to liquidity. For the same index and debt path, more frequent realization can increase underwriting's share, up to rounding. This intentionally incentivizes eligible underwriters to realize premiums and fund both pools for vesting sooner; the benefit is shared through the existing tranche allocation, with no separate caller reward. Total minted premium always equals reported debt growth, and realization does not change borrower debt.

Core implementations are in [contracts/cap](contracts/cap), public interfaces in [contracts/interfaces](contracts/interfaces), and premium accounting in [PremiumVesting.sol](contracts/utils/PremiumVesting.sol).

### Write-offs and market health

A guardian can write off derived unrecoverable debt while a market is unhealthy. A write-off reduces market debt and credit-backed cUSD supply and increases recognized cUSD bad debt, without slashing collateral or adding reserves. The remaining debt may be healthy: the health requirement applies before the write-off, and continued liquidatability is not guaranteed. Liquidation is blocked while the remaining market debt is healthy.

Ignoring integer rounding, a full floating-market write-off with nonzero remaining debt leaves debt at `capital / (1 + liquidationBonus)` and health at `LT × (1 + liquidationBonus)`, with ratios expressed as fractions. With a 2% liquidation bonus, the remaining debt can be healthy at an LT of approximately 98.0392% or higher. The buffer affects collateral locking and LTV validation, but does not enter the health or recoverable-debt calculation.

The buffer must be at least 10% (`0.1e27`) and strictly below LT, both at initialization and when changed. Credit capacity uses `min(LTV, LT - buffer)`, so increasing the buffer or lowering LT tightens the effective borrowing limit even if the stored LTV is higher. With LT capped at 100%, credit capacity is at most 90% of eligible collateral. Even at the maximum 10% liquidation bonus, a full write-off leaves approximately 90.91% of total collateral value as debt, preventing the write-off from immediately reopening borrowing capacity against the same collateral.

Write-offs do not permanently pause borrowing; later repayments or collateral changes may create available credit. A healthy state after a write-off does not mean the recognized loss has been covered or new reserves have arrived. Upgrades do not rewrite previously stored buffers, so existing deployments with buffers below 10% require a configuration update before relying on this bound.

Guardian procedure: when `LT × (1 + liquidationBonus) >= 1` (using fractional ratios), prioritize liquidation while the market is unhealthy, before writing off the remaining unrecoverable debt. Writing off first can make the residual healthy and block collateral recovery through liquidation. If liquidation is unavailable and the guardian proceeds with a write-off, it accepts that residual and the possibility of further write-offs as premiums accrue. The minimum buffer prevents immediate new borrowing against unchanged collateral; it does not enforce liquidation ordering or guarantee recovery of the remaining collateral.

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
yarn test                           # Unit, integration, and fuzz — skips test/invariant
yarn test:invariants                # Invariant campaigns only
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

### Views and event checkpoints

Registry `markets(start, end)`, `tranches(start, end)` and `underwriters(start, end)` use an exclusive end and clamp both bounds to the collection length. An oversized final page returns the remaining entries; a start at or beyond the length returns an empty array. Inverted requested ranges still revert. `(0, type(uint256).max)` returns the full collection. Market `tranches()` returns its full list, bounded to ten entries. Underwriter `registeredTranches()` also returns the full list; curators should keep it small because no count limit is enforced.

`PremiumAccrued(perShare, remainder, staked)` records the vesting state whenever its checkpoint timestamp advances, including idle and rounded-to-zero accruals. Use the event's block timestamp as the new vesting baseline. The event precedes the calling operation's funding or balance changes: replay subsequent `Fund`, `Transfer`, `OptIn`, `OptOut`, `Claimed` and `SetVestingPeriod` events in order. Project accrual between checkpoints using the configured period and contract rounding. Tranche and underwriter NAV exclude separately claimable cUSD premiums; the wrapper includes its claimable cUSD premium in `totalAssets()`.

`PremiumIndexUpdated(liquidityIndex, underwriterIndex)` records floating-market index baselines at initialization and premium checkpoints, including empty-market resets. Funded same-timestamp calls that keep the cached indices emit no additional checkpoint. The liquidity index is market-local, not the global IRM index. Debt reconstruction must also replay debt movements, IRM updates and market multiplier changes with the contract's rounding; the checkpoint alone is not a debt balance.

### Zap authorization for queued redemptions

Queued claims follow [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540): the caller must be the request controller or its approved operator. ERC20 share allowance can authorize `requestRedeem`, but does not authorize claiming an existing request.

For a user-controlled request, approve a trusted zap with `setOperator(zap, true)` on the cUSD, tranche or underwriter contract. The zap can then call `requestRedeem(shares, user, user)` and, once claimable, `redeem(requestId, shares, receiver, user)` or the corresponding `withdraw`. Revoke approval with `setOperator(zap, false)`. This approval is separate from the Vault's ERC6909 operator approval used for collateral deposits.

Operator approval gives the zap authority to direct payouts and transfer requests. The zap must authenticate the user for every operation: direct calls should derive the owner/controller from the caller, and relayed calls must verify a user-signed instruction binding the vault, request, amount, recipient and any swap parameters, with a nonce and deadline. Apply these checks throughout any batching or callback paths. A public bundler that forwards arbitrary calls using its own operator approval is unsafe: another caller could use that approval to redirect a user's redemption. Signing an operator approval alone does not authenticate the subsequent zap operation. No zap implementation or signed operator extension is included here.

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
