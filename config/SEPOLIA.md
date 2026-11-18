# Cap Network on Sepolia: deployment and scenario suite

`script/DeploySepolia.s.sol` deploys a fresh Cap Network stack on Ethereum Sepolia
(`11155111`) and then plays out a storyline of 60-odd scenarios with 24 distinct
operator wallets, so the UI has markets, tranches, underwriter pools, operator groups,
live debt, a liquidation and queued exits to render from the first block. It does not
use the migration services or any existing cUSD/stcUSD proxies.

The signing wallet is the **deployer and admin**: it pays gas and the wrapper seed, holds
every protocol role (ADMIN, GOVERNOR, GUARDIAN, KEEPER, LIQUIDATOR, WHITELISTED), owns
the mock tokens and the wstETH test feed, and keys the CreateX salts. Every other actor is
derived from `ACTORS_MNEMONIC` and funded by the deployer in-script, so the whole cast is
recoverable from one phrase.

## What gets deployed

| Piece | Detail |
| --- | --- |
| Core | Implementations, UUPS proxies, beacons, `Registry`, `Oracle`, `InterestRateModel`, `Stablecoin` (cUSD), `Wrapper` (stcUSD), all through CreateX under `SALT_NAMESPACE` (default `keccak256("cap-network-sepolia-v2")`). |
| Reserve token | `mUSDC`, a 6-decimal `TestnetERC20`. Minting is `onlyOwner`; the owner is the deployer. The wrapper seed (1 cUSD) is minted here, so no faucet USDC is needed. |
| Collateral | `mWETH` (18dp), `mWBTC` (8dp), `mwstETH` (18dp, non-rebasing like real wstETH; its admin feed starts at $2,150), all `TestnetERC20`, admin-mint only. |
| Price feeds | `mWETH` -> Chainlink ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306`; `mWBTC` -> Chainlink BTC/USD `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` (both 8 decimals, 24h staleness); `mwstETH` -> `TestnetPriceFeed`, an owner-settable Chainlink-shaped feed that always reports a fresh `updatedAt`. The liquidation scenario moves it. Behind each Chainlink feed sits a second `TestnetPriceFeed` as the oracle's secondary source, seeded with the live price at deploy time: if Chainlink Sepolia stops updating for more than 24h, prices fall through to it instead of going to zero. |
| Rates | Liquidity curve 5% base, 10% at 80% utilisation, 20% at 100%; shared defaults otherwise (multiplier 1-2x, max underwriting rate 100%, liquidation bonus 2%, LT 80%, buffer 10%, target health 1.25, 12h vesting). |

Token and feed addresses are CREATE3 under the same namespace, so `save()` can predict and
verify them like the infrastructure.

## The cast

Indices are on `ACTORS_MNEMONIC` (`m/44'/60'/0'/0/<index>`). The console prints every
address at the start of a run and `config/sepolia-scenarios.json` records them.

| Index | Label | Role in the story |
| --- | --- | --- |
| 0 | Atlas Capital (owner A) | Owns *Atlas ETH Credit*; co-owns the Cinder markets |
| 1 | Boreal Credit (owner B) | Owns *Boreal Fixed Term* |
| 2 | Cinder Markets (owner C) | Owns *Cinder BTC Credit* and *Cinder wstETH Credit* |
| 3-8 | Borrowers A-F | Members of the various borrower groups |
| 9-13 | Depositors A-E | Tranche and cUSD/stcUSD depositors |
| 14-16 | Curators A-C | One per underwriter pool |
| 17-19 | Allocators A-C | Operational wallets that move pool capital |
| 20-22 | Pool LPs A-C | Deposit into underwriter pools |
| 23 | Liquidator | Holds `LIQUIDATOR` and repays the liquidation |

Owners and curators also hold `WHITELISTED` so they create their own groups, markets and
pools. The deployer keeps `KEEPER`, `GOVERNOR` and `GUARDIAN` and plays those parts.

Two ways to source the phrase:

- **A fresh mnemonic.** Two testnet secrets (deployer key, actors phrase), fully separate.
- **The deployer's own phrase.** If the deployer wallet came from a seed phrase, the standard
  HD-wallet answer is to make the actors the next accounts of that phrase: set
  `ACTORS_INDEX_OFFSET=1` (or the first unused account) and the table above shifts by that
  much, so owner A is account 1 and the liquidator account 24. Any wallet that imports the
  phrase then shows deployer and actors side by side. The script reverts if an actor would
  coincide with the deployer, so forgetting the offset cannot make the admin wallet "owner A".

There is no standard way to derive child wallets from a bare private key (BIP-32 needs a
chain code the key does not carry), so a deployer created as a raw key gets a fresh phrase.

## Sepolia ETH budget

Numbers from the local rehearsal (334 transactions, identical calldata to a real run):

| Sender | Gas | @ 1 gwei | @ 3 gwei | @ 10 gwei |
| --- | --- | --- | --- | --- |
| Deployer (deploys, config, funding txs) | 54.7M | 0.055 ETH | 0.164 ETH | 0.547 ETH |
| All 24 actors together | 41.8M | 0.042 ETH | 0.125 ETH | 0.418 ETH |
| Heaviest single actor (owner A) | 9.4M | 0.009 ETH | 0.028 ETH | 0.094 ETH |

The deployer also sends `ACTOR_FUNDING` (default `0.05 ether`) to each of the 24 actors:
**1.2 ETH** at the default, topped up only to that level so a re-run does not double-fund.
Whatever the actors do not spend stays in their wallets for driving the UI later.

Put at least **2 ETH** in the deployer at a gas price up to ~5 gwei (0.27 own gas + 1.2
funding + margin). If Sepolia is running hot (~10 gwei), set `ACTOR_FUNDING=100000000000000000`
(0.1 ETH, enough for the heaviest actor) and hold **~3.5 ETH**. The script refuses to start
if the deployer cannot cover the funding step, and the simulation prints the current
estimate for the deployer's own gas.

## Prepare and simulate

Toolchain as in the repository README (Foundry v1.5.1, solc 0.8.36, Osaka).

```sh
yarn install --frozen-lockfile --ignore-scripts
export SEPOLIA_RPC_URL='https://ethereum-sepolia-rpc.publicnode.com'
export ACTORS_MNEMONIC='<a fresh 12-word phrase you keep>'

# dry run against the live chain state: no signing, no sending
yarn deploy:sepolia --sender <deployer address>
```

The dry run checks the chain id, the sender, CreateX, both Chainlink feeds (fresh within
24h, positive, 8 decimals), the deployer's balance against the funding step, and that the
namespace is unused for every predicted address. It then executes the whole storyline in
simulation and prints the scenario log and Forge's gas estimate.

`vm.warp` steps the simulation three minutes per scenario. On chain those transactions are
spread over an hour of real blocks, which flips premium accrual, vesting checkpoints and
rate updates onto their "time has passed" branches; warping makes the simulated trace take
the same paths. It changes nothing on chain.

To pin the dry run to a block, add `--fork-block-number <n>`. For a full rehearsal that
actually sends the 334 transactions, fork into anvil and broadcast there with the Foundry
test keys, exactly as the real run would:

```sh
anvil --fork-url $SEPOLIA_RPC_URL --fork-block-number <n> --chain-id 11155111 --hardfork osaka
ACTORS_MNEMONIC='<any throwaway phrase>' forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url http://127.0.0.1:8545 --private-key <anvil key 0> --broadcast --slow --skip-simulation
```

`ACTORS_MNEMONIC` defaults to Foundry's public test phrase for simulations and tests; a
broadcast with that phrase is refused, because anyone can sweep those keys the moment they
hold Sepolia ETH.

## Deploy

```sh
yarn deploy:sepolia --account cap-sepolia --sender <deployer> --broadcast --slow --skip-simulation --gas-estimate-multiplier 200 --verify
```

`--sender` is needed next to `--account`: Forge resolves the keystore's address only when it
unlocks it, after the script has already checked who the deployer is.

Why these flags:

- `--slow` sends one transaction at a time and waits for its receipt. The storyline is
  order-dependent across 25 signers; this keeps it in script order. Expect roughly an hour
  of wall time at Sepolia's 12s blocks.
- `--skip-simulation` makes Forge estimate each transaction's gas with `eth_estimateGas`
  right before sending it, against the real chain state, instead of from a replay at a
  single timestamp. Without it, calls that settle accrued premium (`setTrancheWeights`,
  `chargePremium`, `setVestingPeriod`, `report`, ...) are estimated on their cheap no-time-elapsed
  branch and run out of gas on chain; the rehearsal reproduced exactly that.
- `--gas-estimate-multiplier 200` doubles each estimate as headroom. Unused gas is refunded.

### Etherscan verification

Set `ETHERSCAN_API_KEY` (an Etherscan v2 key works for Sepolia) and add `--verify` to the
broadcast. Forge then verifies the ten contracts the script creates directly (the nine
implementations and `BeaconFactory`) as their transactions are mined.

Forge does not submit contracts created inside other calls: the CreateX proxies and beacons,
the AccessManager, the adapter library, the mock tokens and feeds, and every market, tranche
and pool the Registry deploys through the factory. After `save()` has written the config, run

```sh
bash script/sepolia/verify-sepolia.sh
```

`script/sepolia/VerifyArgs.s.sol` rebuilds each of those 36 contracts' constructor arguments
from `config/cap-v2.json` and `config/sepolia-scenarios.json`, checks them against the on-chain
runtime code, and the shell loop feeds them to `forge verify-contract`. Etherscan marks later
contracts with the same bytecode as "Similar Match" automatically, so some submissions come
back "already verified"; the loop treats that as success. Proxies show their implementation on
Etherscan once both are verified ("Is this a proxy?" on the contract page).

An interrupted broadcast has deployed part of the stack. Keep the broadcast artifacts and
resume with the same account, namespace and mnemonic:

```sh
yarn deploy:sepolia --account cap-sepolia --sender <deployer> --broadcast --slow --skip-simulation --gas-estimate-multiplier 200 --resume
```

Optional: `SCENARIO_WRITEOFF=true` adds scenario 9.3, where the guardian writes off
unrecoverable debt after a deeper price crash. It leaves recognised bad debt on cUSD for
the life of the deployment, which changes every cUSD exit price, so it is off by default.

## Step by step

1. `git am sepolia-scenarios.patch` on `bc5be38`, `yarn install --frozen-lockfile --ignore-scripts`, `forge remappings > remappings.txt`, `forge test --match-path 'test/integration/SepoliaDeployment.t.sol'`.
2. `cast wallet import cap-sepolia --interactive` with the deployer key; `cast wallet address --account cap-sepolia` must print the deployer.
3. Fund the deployer: >= 2 ETH (see the budget above; more if gas is high). No USDC needed.
4. `export SEPOLIA_RPC_URL=...`, `export ACTORS_MNEMONIC='...'` (the fresh actors phrase), `export ETHERSCAN_API_KEY=...`.
5. Dry run: `yarn deploy:sepolia --sender <deployer>`; read the actor table and the scenario log, check the feed prices it prints.
6. Broadcast: the command under *Deploy*. About an hour. If it stops, the same command plus `--resume`.
7. `yarn save:sepolia --sender <deployer>` writes `config/cap-v2.json`; `EXPECT_DEPLOYER_ADMIN=true yarn check-roles --rpc-url sepolia` must end with "roles match the table".
8. `bash script/sepolia/verify-sepolia.sh` verifies the 36 internally created contracts on Etherscan.
9. Hand `config/sepolia-scenarios.json` and the actors phrase to whoever drives the UI; commit `config/cap-v2.json`.

## Verify and save

After all transactions succeeded, from the same deployer (read-only, `--sender` is enough):

```sh
yarn save:sepolia --sender <deployer address>
EXPECT_DEPLOYER_ADMIN=true yarn check-roles --rpc-url sepolia
```

`save()` predicts the infrastructure and token addresses, checks the deployed contracts,
roles, wrapper seed, rate curve, oracle sources and the mock-token owner, reads the
implementations off the proxies and beacons, and then replaces the `11155111` entry of
`config/cap-v2.json` (deployer, `stablecoinUnderlying` = mUSDC, implems, infra, and a
`testnet` block with the mock tokens and feeds). `yarn save:sepolia` reformats the file
afterwards; `yarn lint:config` checks it. Simulation through `run()` never touches it.

A broadcast also writes `config/sepolia-scenarios.json`: actors, tokens, every operator
group id, the four markets with their tranches and owner roles, the three pools, and the
retired Atlas tranche. That file is for the UI team; it is not written on a dry run unless
`SEPOLIA_MANIFEST=true`.

## The storyline

Every scenario is signed by the wallet that would do it in production and is logged with
its id, title and a one-line explanation, so the broadcast log is the catalogue. State
dependencies fix the order: underwriters allocate and deallocate before any debt locks
tranche capital, and the liquidation runs after all borrowing so its price move only
touches the market built for it.

| Id | Scenario | What it demonstrates |
| --- | --- | --- |
| 0.1 | Deploy admin-mintable testnet tokens | mUSDC (6dp) backs cUSD; mWETH (18dp), mWBTC (8dp) and mwstETH (18dp) are collateral. Only the admin can mint. |
| 0.2 | Deploy Cap infrastructure through CreateX | Implementations, proxies, beacons, registry, wrapper seed and protocol roles, all held by the deployer. |
| 0.3 | Governor configures oracle sources | mWETH -> Chainlink ETH/USD, mWBTC -> Chainlink BTC/USD (24h staleness), mwstETH -> admin-set feed. |
| 1.1 | Admin whitelists operators and names a liquidator | Market owners and curators get WHITELISTED so they can create groups, markets and pools themselves. A separate liquidator wallet gets LIQUIDATOR. |
| 1.2 | Deployer funds the cast | Each actor is topped up to the configured Sepolia ETH balance and minted the mock tokens its role needs. |
| 2.1 | Admin creates market-owner groups | Three owner groups under GOVERNOR: Atlas [owner A], Boreal [owner B], Cinder [owner C + owner A] (co-owned). |
| 2.2 | Admin creates curator groups | One curator group per underwriter pool, each with a single curator, administered by GOVERNOR. |
| 3.1 | Owner A creates 'Atlas ETH Credit' (floating, 3 tranches, mixed collateral) | Tranches: mWETH senior 60%, mwstETH mezzanine 30%, mWBTC junior 10%. Owner sets LTV 60% and a 10% underwriter rate. |
| 3.2 | Owner B creates 'Boreal Fixed Term' (fixed-term loans) | Two mWETH tranches 80/20, terms 1-30 days, 1 day grace. Owner sets LTV 50% and a 15% underwriter rate. |
| 3.3 | Owner C creates 'Cinder BTC Credit' (floating, single tranche, co-owned) | One mWBTC tranche at 100%. Owner C sets LTV 40% and a 20% underwriter rate; owner A co-administers through the shared Cinder group. |
| 3.4 | Owner C creates 'Cinder wstETH Credit' (floating, the liquidation sandbox) | Two mwstETH tranches 70/30 priced by the admin feed. LTV 65% (the maximum under LT 80% - buffer 10%) so a scripted price drop makes it liquidatable. |
| 4.1 | Owner A creates borrower group 'Atlas Borrowers A' and wires it to the market | Group under the Atlas owner role with borrowers A and B, then `market.setBorrowerRole(group)`. Until this, nobody can draw. |
| 4.2 | Owner A edits the group's membership directly on AccessManager | Adds borrower C (`grantRole`) and removes borrower B (`revokeRole`). The market keeps pointing at the same group. |
| 4.3 | Owner B creates 'Boreal Borrowers A' [E, F] for the fixed market | Same pattern on the fixed-term market: a group under the Boreal owner role, then `setBorrowerRole`. |
| 4.4 | Owner C creates 'Cinder BTC Borrowers' [B, F]; co-owner A then swaps F out for C | Two members of one owner group administering the same borrower group: C creates it, A revokes F and grants C. |
| 4.5 | Owner C creates 'Cinder wstETH Borrowers A' [C] | A single-member borrower group for the liquidation sandbox. It is swapped for a fresh group after the liquidation (9.4). |
| 5.1 | Owner A creates 'Atlas LPs v1' [A, B, C] and sets it as the senior tranche's depositor role | A named depositor group replaces the closed role the registry minted at creation. Only members can deposit into Atlas tranche 0. |
| 5.2 | Owner A admits depositor D to the mezzanine tranche's default closed role | No new group: the owner grants membership of the registry-minted depositor role (read from AccessManager) directly. |
| 5.3 | Owner A opens the junior tranche to the public | `tranche.setDepositorRole(PUBLIC_ROLE)`: anyone, including underwriter pools, can deposit mWBTC into Atlas tranche 2. |
| 5.4 | Owner B admits depositors A and B to Boreal senior, C to Boreal junior | Fixed-market tranches use the registry-minted closed roles; the owner grants members one by one. |
| 5.5 | Owner C admits depositors to the Cinder tranches | BTC tranche: C and E. wstETH senior: D and E. wstETH junior: A. |
| 6.1 | Depositors A, B, C supply mWETH to Atlas senior and opt in to premiums | 10 / 5 / 2.5 mWETH. The first deposit carves out the dead shares. `optIn()` makes the position earn cUSD premium. |
| 6.2 | Depositor D supplies mwstETH to Atlas mezzanine; E supplies mWBTC to the public junior | 20 mwstETH and 0.5 mWBTC. E was never admitted anywhere: the junior tranche is public. |
| 6.3 | Depositors fund the Boreal fixed market | A: 4 mWETH and B: 6 mWETH into senior, C: 1 mWETH into junior. |
| 6.4 | Depositors fund the two Cinder markets | BTC: C 1 mWBTC, E 0.25 mWBTC. wstETH senior: D 30, E 20 mwstETH. wstETH junior: A 10 mwstETH. |
| 6.5 | Depositors D and E mint cUSD from mUSDC; D wraps half into stcUSD | D: 10,000 mUSDC -> cUSD, opts in, wraps 5,000 cUSD. E: 5,000 mUSDC -> cUSD and opts in. Permissionless, no role needed. |
| 6.6 | Liquidator and borrowers hold cUSD reserve | Liquidator mints 200,000 cUSD to repay a liquidation later; borrowers E, F mint 1,000 cUSD each to cover fixed-loan premium on repayment. |
| 7.1 | Curator A creates the 'Cap WETH Underwriter' pool with allocator and depositor groups | Curator creates the pool, mints child groups under its curator role: allocators [Allocator A], depositors [LP A, LP B], and wires both. |
| 7.2 | Owners A and B admit the pool contract to their senior tranches | A pool is a depositor like any other: owner A adds the pool address to 'Atlas LPs v1', owner B grants Boreal senior's closed role. |
| 7.3 | LP A deposits 20 mWETH; Allocator A spreads it across two markets and picks a default | No default yet, so the deposit sits idle. Allocator A allocates 12 to Atlas senior and 6 to Boreal senior, then sets Atlas senior as the default route. |
| 7.4 | LP B deposits 10 mWETH, which auto-routes to the default tranche | With a default set, the pool mints tranche shares in the same transaction as the deposit. |
| 7.5 | Allocator A deallocates: 2 mWETH instantly from Boreal, 1 mWETH queued from Atlas | `deallocate()` redeems unlocked tranche shares at once; `deallocateAsync()` queues an ERC-7540 request that fills as capital unlocks. |
| 7.6 | Keeper reports both positions | `report()` re-marks the pool's book against the tranche and claims any vested premium into the pool. |
| 7.7 | Curator B creates the 'Cap WBTC Underwriter' pool and opens deposits to the public | Allocator group [Allocator B]; depositor role set to PUBLIC. Registers Cinder BTC and the public Atlas junior tranche. |
| 7.8 | Owner C admits the WBTC pool to the Cinder BTC tranche; LP C deposits; Allocator B allocates | LP C (never whitelisted) deposits 2 mWBTC into the public pool. Allocator B puts 1.5 into Cinder BTC, 0.25 into Atlas junior, and makes Cinder BTC the default. |
| 7.9 | Curator C creates the 'Cap wstETH Underwriter' pool | Allocators [Allocator C], depositors [LP A]. Registers Cinder wstETH senior (the liquidation sandbox) and Atlas mezzanine. |
| 7.10 | Owners admit the wstETH pool; LP A deposits 40 mwstETH; Allocator C allocates 30 + 5 | Owner C grants the pool on Cinder wstETH senior, owner A on Atlas mezzanine. Default route becomes Cinder wstETH senior. |
| 7.11 | Curator C swaps the allocator group: 'v2' [Allocator A] replaces [Allocator C] | `createChildRoles` under the curator role, then `setAllocatorRole(v2)`. Allocator C loses the ability to move capital; Allocator A gains it. |
| 7.12 | New allocator A pulls the pool out of Atlas mezzanine; Curator C deregisters that tranche | `deallocate()` the whole Atlas mezzanine position (unlocked: Atlas has no debt yet), then `removeTranche()` closes it to new allocations. |
| 8.1 | Borrower A draws 5,000 cUSD from Atlas | Floating borrow mints credit-backed cUSD to the recipient and records scaled debt against the market. |
| 8.2 | Owner A swaps Atlas to borrower group B [Borrower D]; D draws 20,000 cUSD | A new group replaces group A on the market. Members of A keep their debt exposure but can no longer draw; D can. |
| 8.3 | Borrower A repays 1,000 cUSD to Atlas | `repay()` burns credit-backed cUSD from the caller; repayment is open to anyone holding cUSD, not just group members. |
| 8.4 | Borrower E opens a 7-day fixed loan of 3,000 cUSD on Boreal; F opens 14 days for 2,000 | Fixed loans charge the term's liquidity + underwriting premium up front into the debt. `maxPremium` is uncapped here. |
| 8.5 | Borrower E tops up loan #0 by 500 and extends it 7 days; Borrower F repays loan #1 in full | `borrowMore()` adds principal over the remaining term; `extend()` buys more term; `repay(max)` clears principal plus premium. |
| 8.6 | Owner B swaps Boreal to borrower group B [A, E]; Borrower A opens a 3-day loan of 1,000 | Borrower A now borrows on two markets; F, dropped with the swap, can no longer open loans here. |
| 8.7 | Borrower B draws 10,000 cUSD from Cinder BTC | Borrower B is a member of the Cinder BTC group (4.4) but was removed from Atlas (4.2). |
| 8.8 | Borrower C draws the full available credit from Cinder wstETH | `borrow(max)` fills `availableCredit` exactly, which puts the market at its LTV so the price drop in 9.1 tips it under LT. |
| 8.9 | Anyone realises accrued premium on the floating markets | `chargePremium()` is permissionless: it mints the elapsed premium to cUSD holders and tranches. Early on it is tiny. |
| 9.1 | Admin drops the wstETH feed 25% (2,150 -> 1,612.50) | Cinder wstETH was borrowed to its 65% LTV; at 75% of the price its debt exceeds 80% of capital and the market is unhealthy. |
| 9.2 | Liquidator repays up to `maxLiquidatable` and receives slashed mwstETH | Liquidation burns the liquidator's cUSD, slashes junior collateral first then senior, and leaves the market at target health 1.25. |
| 9.3 | Admin crashes the feed to 215; Guardian writes off unrecoverable debt (opt-in) | `SCENARIO_WRITEOFF=true` only. Leaves recognised bad debt on cUSD for the rest of the testnet's life. |
| 9.4 | Admin restores the feed to 2,150; Keeper reports the wstETH pool's loss; Owner C swaps the borrower group | `report()` marks the pool's slashed position down. The sandbox then moves to borrower group B [Borrower D] for further UI testing. |
| 10.1 | Owner A lowers Atlas LTV to 55%, reweights tranches 50/30/20, raises underwriter rate to 12% | `setLoanToValue`, `setTrancheWeights` (settles premium under the old weights first) and `setUnderwriterRate`, all owner calls. |
| 10.2 | Owner A adds a fourth Atlas tranche (mWETH) and a fifth (mwstETH), then removes the fifth | `createTranche` deploys and reweights 45/30/15/10; a second one goes to 45/30/15/5/5; `removeTranche` retires it and returns to four. The retired tranche stays visible with zero lock. |
| 10.3 | Owner A swaps Atlas senior to depositor group 'Atlas LPs v2' [A, E, WETH pool]; E deposits 1 mWETH | B and C keep their shares but can no longer deposit; E can. The pool stays in so its default route keeps working. |
| 10.4 | Co-owner A raises Cinder BTC's LTV to 45% | Owner A acts on a Cinder market through the shared Cinder owner group created in 2.1. |
| 11.1 | Governor tunes Boreal: market multiplier 1.5x, term band 1-60 days; Atlas target health 1.3 | Governor-only market setters. Outstanding fixed principal does not jump; the multiplier applies to the next term. |
| 11.2 | Governor shortens premium vesting: Atlas senior 6h, cUSD 8h; sets a term-multiplier slope | `setVestingPeriod` checkpoints elapsed vesting first. `setTermMultiplierSlope` makes longer fixed terms cost more. |
| 11.3 | Guardian tightens Cinder BTC: liquidation threshold 85%, buffer 15% | Guardian-only risk setters. Effective credit is min(LTV, LT - buffer) = min(45%, 70%) so the owner's LTV still binds. |
| 11.4 | Keeper reports every pool position | After the price round-trip and the reweights, the keeper refreshes each pool's cached values. |
| 12.1 | Depositor A instantly redeems a quarter of its Atlas senior shares; B queues half | Senior is unlocked because the junior tranches cover Atlas's debt. `instantRedeem` pays now; `requestRedeem` queues an ERC-7540 request. |
| 12.2 | Depositor E queues a full exit from the locked Atlas junior tranche | Junior capital backs the debt, so the request stays pending until debt is repaid or capital arrives above it. |
| 12.3 | LP B queues a redemption of 5 uwWETH shares from the WETH pool | Pool exits are also ERC-7540: the request fills from idle assets and finalized deallocations. |
| 12.4 | Depositor D unwraps 2,000 stcUSD and instantly redeems 1,000 cUSD for mUSDC; E queues 500 cUSD | stcUSD -> cUSD via the wrapper's ERC-4626 redeem; cUSD -> mUSDC instantly while reserves allow, otherwise queued. |
| 12.5 | Opted-in holders claim premium | `claim()` pays whatever has vested so far; this early it is small or zero, but the call path is exercised for the UI. |

End state, for reference: Atlas carries ~24,000 cUSD of floating debt against four live
tranches (one more retired); Boreal has two open fixed loans and one repaid; Cinder BTC has
10,000 cUSD out; Cinder wstETH was liquidated back to health 1.25 and reassigned to a new
borrower group; the wstETH pool carries a reported loss; two tranche exits, one pool exit
and one cUSD exit sit in ERC-7540 queues.

## After the run

- Mint more test tokens to anyone from the deployer: `TestnetERC20.mint(to, amount)` or
  `mintBatch`. Nobody else can.
- Move the wstETH price for more liquidation rehearsals: `TestnetPriceFeed.setAnswer(int256)`
  from the deployer. `setFrozenUpdatedAt(ts)` rehearses a stale feed; zero means "now".
- Grant more wallets into any group: the group's admin (owner or curator role holder)
  calls `AccessManager.grantRole(roleId, account, 0)`. Role ids are in the manifest.
- The two Chainlink feeds are real (1h heartbeat on Sepolia). If either goes quiet for more
  than 24h the oracle reads the matching fallback feed, frozen at the deploy-time price, until
  Chainlink resumes; the deployer can move a fallback with `setAnswer` like the wstETH feed.
- Loan calendar: Boreal loan #0 (Borrower E) expires 14 days after the run, loan #2
  (Borrower A) after 10 days, loan #1 is repaid. An expired loan does not break anything: it
  sits until the borrower repays or, after the 1-day grace, the keeper rolls it with
  `extendAdmin` and charges arrears. Floating debt accrues under 2% a week at these rates and
  every market sits at health well above 1.5, so nothing needs liquidating unless the admin
  moves the wstETH feed again on purpose.

## Regression checks

```sh
forge test --match-path 'test/integration/SepoliaDeployment.t.sol' -vv
```

Runs the actual script against mocked Sepolia externals (CreateX, both Chainlink feeds)
from an arbitrary wallet, then asserts the storyline's end state: four markets with debt,
three pools, group membership after every edit and swap, the public junior and pool,
the retired tranche, the liquidation payout, the write-off opt-in, queued and paid exits,
admin-only minting, oracle prices, the manifest, and the guards (stale or dead feeds,
wrong chain, default sender, underfunded deployer, reused namespace, undeployed `save()`,
public mnemonic on a broadcast).
