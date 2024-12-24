## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ FOUNDRY_PROFILE=release forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

### Testnet Deploy

Prepare config in `~/.foundry/foundry.toml`
```toml
[rpc_endpoints]
anvil = "http://127.0.0.1:8545"
```

Create anvil wallet
```shell
cast wallet import anvil --interactive
```

Start anvil
```shell
anvil -f $RPC_URL --accounts 3 --balance 300 --no-cors --block-time 5
```

Deploy
```shell
forge script --rpc-url anvil script/DeployTestnetVault.s.sol:DeployTestnetVault --account anvil --broadcast
```

Latest testnet deploy:
- Mock USDT: 0x9ED3608F2f1469C39b5F2c75fFCcD8862104347c
- Mock USDC: 0x8BC89D0BC47e61263587ABe02CC2dC9194064747
- Mock USDx: 0x04eAafF238008dD867cFEBA290e23a2660C813c2
- Registry: 0x9c0897B7d647D36620b43585de3F57eF596C94BB
- Minter: 0xfE84D26264280dD3DC9BFCc9E2034AED9712B3eb
- Vault: 0x10A81f0F2386Bbf8DFfdeeb404cf7332ac9A05a7
- cUSD: 0x8E6112d494da56011b5d1424A91D2d6AC83cedBC
- Mock Oracle: 0xEe9c4dE8B477bb4e10EfEB7454107F9C3F55e681