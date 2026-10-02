# Fresh Cap Network deployment on Sepolia

`script/DeploySepolia.s.sol` deploys new implementations and new infrastructure
proxies and beacons on Ethereum Sepolia (`11155111`). It does not use the migration
services or existing cUSD/stcUSD proxies.

Any wallet can run it. The wallet that signs is the deployer: it pays the wrapper
seed, holds every protocol role, and keys the CreateX salts, so each wallet gets its
own stack at its own addresses. The team deployment checked into
`config/cap-v2.json` was made by `0x25AcaAb315916F8FFe39eb29Ba403236469Df41F`.

## Configuration

- Deployer, admin, governor, guardian, keeper, and liquidator: the signing wallet.
- Circle USDC reserve, 6 decimals:
  `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`.
- WETH collateral token, 18 decimals:
  `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`.
- Chainlink ETH/USD feed:
  `0x694AA1769357215DE4FAC081bf1f309aDC325306`.
  The deployed adapter normalizes its answer to 18 decimals. Answers must be
  positive and no more than two hours old. There is no secondary feed.
- Reserve investment vault: unset (`address(0)`); reserves stay in Stablecoin.
- Registry keeps its required ADMIN and REGISTRY roles. The deployer also receives
  WHITELISTED (role `7`) so the testnet operator can create markets immediately. No
  markets, tranches, or underwriter pools are created by the deployment.
- Liquidity curve: 5% annual base, 10% at 80% utilization, 20% at full utilization.
  The term multiplier slope starts at zero. Shared deployment defaults remain:
  market multiplier range 1–2, maximum underwriting rate 100%, liquidation bonus
  2%, liquidation threshold 80%, buffer 10%, target health 1.25, utilization
  averaging period one hour, and stablecoin premium vesting period 12 hours.

The wallet must hold at least **1 USDC** for the permanent wrapper seed. A balance
of 20 USDC leaves 19 USDC after deployment. Gas is paid separately in Sepolia ETH;
use the simulation's current estimate to check the ETH balance.

Sources: [Circle USDC addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses),
[Circle faucet](https://faucet.circle.com/),
[Chainlink ETH/USD example](https://docs.chain.link/data-feeds/api-reference).

## Prepare and simulate

Use the Node, Yarn, and Foundry versions documented in the repository README.
The checked-in Solidity compiler and EVM target are used without overrides.

```sh
yarn install --frozen-lockfile --ignore-scripts
export SEPOLIA_RPC_URL='https://ethereum-sepolia-rpc.publicnode.com'
yarn deploy:sepolia --sender <your wallet address>
```

This command simulates without signing or sending transactions. Without a wallet,
`--sender` names the deployer; Forge's default sender is rejected. It checks the
chain, sender, token decimals, USDC seed balance, feed freshness, CreateX, unused
deployment addresses, and resulting deployment configuration. Foundry then
simulates the individual transactions and prints its gas estimate.

The default CreateX namespace is `keccak256("cap-network-sepolia-v1")`:

```text
0xe46d8bac86bfab5871291c0a491d48c5f7a48cef9f2ea02da01121e7af858fd9
```

`SALT_NAMESPACE`, if set, overrides it. Use the same value for simulation,
broadcast, and saving. A used namespace is rejected before deployment starts.

## Deploy

Sign with a Foundry keystore account, hardware wallet, or private key; Forge takes
the deployer from it. For a keystore account named `cap-sepolia`:

```sh
yarn deploy:sepolia --account cap-sepolia --broadcast --slow
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts on Etherscan.

`--slow` waits for each transaction to succeed before sending the next. This is a
multi-transaction deployment: an interrupted broadcast may have deployed part of
the stack. Preserve its Foundry broadcast artifacts and resume the recorded
transactions with the same account and namespace instead of starting a new run:

```sh
yarn deploy:sepolia --account cap-sepolia --broadcast --slow --resume
```

The same command with `--resume --verify` verifies a completed deployment without
sending anything, since every recorded transaction already has a receipt.

The script uses the deployer's USDC for the wrapper seed, mints the intermediate
cUSD to that wallet, and locks the wrapper shares at `DeadShares.HOLDER`.
Operational role environment variables used by the generic deployment script do
not override this Sepolia configuration.

## Verify and save the completed deployment

After all transactions have succeeded, before configuring or using markets, run
`save()` as the same deployer (no transactions are sent, so `--sender` is enough):

```sh
yarn save:sepolia --sender <your wallet address>
EXPECT_DEPLOYER_ADMIN=true yarn check-roles --rpc-url sepolia
```

`save()` sends no transactions. It reads the predicted infrastructure addresses
from Sepolia, checks the deployed contracts, roles, wrapper seed, rate curve, and
WETH oracle, then reads implementation addresses from the proxies and beacons.
Only then does it replace the `11155111` entry of `config/cap-v2.json`, including
its `deployer`. Other chain entries are preserved, and the yarn script reformats the
file after Forge writes it. Simulation through `run()` never changes this file.

The checked-in entry is the team deployment. If you deploy your own stack, keep your
saved entry local and do not commit it.

The role-checker flag explicitly expects this deployment to retain the deployer
as admin. The generic checker's default remains the separate-admin deployment.

## Create markets

The deployer holds WHITELISTED, which opens Registry's market, underwriter, and
child-role creation functions. The admin can grant role `7` on AccessManager to
other market creators. WETH is already priced when a WETH-backed market is created;
additional collateral tokens need their own Oracle sources first.

A new market cannot lend until its owner role sets a loan-to-value (default 0, at
most liquidation threshold minus buffer) and the governor sets each tranche's
`maxCapital` (default 0). Borrowers and depositors are admitted through the closed
roles the Registry creates for each market and tranche.

## Regression checks

```sh
forge test --match-path 'test/integration/*Deployment.t.sol' -vv
```

These cover the actual Sepolia script with six-decimal mock USDC, run from an
arbitrary wallet, plus the shared deployment services: retained admin, complete role
wiring, a deployer-only creator whitelist, separate stacks per wallet, oracle
validation, wrapper funding, a deposit/wrap/unwrap/redeem round trip, wrong-network
and missing-sender rejection, stale and invalid feeds, insufficient seed funds, and
reused namespaces.
