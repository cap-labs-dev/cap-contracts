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
