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
# skip simulation is needed to avoid the ERC1967InvalidBeacon error
# this happens because the script is trying to simulate a clone on a beacon that is not deployed yet
forge script --rpc-url anvil script/DeployTestnetVault.s.sol:DeployTestnetVault --account anvil --skip-simulation --broadcast
```

Latest testnet deploy:
- Mock USDT address: 0x8bcc54D087CdB40491722F33dEF6C7f3abF290cF
- Mock USDC address: 0xbDb6B30d716b7a864e0E482C9D703057b46BF218
- Mock USDx address: 0xd31976b835D4E879Fa89b10AAa0180a80E2833e3
- Registry address: 0x1De99e7c391D0c1CbCB6f6604449a09421162723
- Minter address: 0xc1808DA905e5AF9F9A887083AB165cC24fF75a2C
- Lender address: 0x443775362DD8DA58d98D87a77923507EDEA5EAF0
- Vault address: 0xeBc792641e73cFa9BC93a1Ae884BFe82cc2c23c4
- cUSD address: 0x992bAAd7EE067E980939013ffa597925210Ec0d9
- scUSD address: 0xDE2E58B286cDa4e728A8af388CB1b50D8744985D
- Staked Cap Implementation address: 0x6e8eD0B3d92723d2D638cf0de16de59b8e933611
- Principal Debt Token Implementation: 0xCC5572a04C4BA9C2F9fCE0eA7fBdc8EBF36e9570
- Interest Debt Token Implementation: 0x9560708Aad7b32Baf4F0E2990c7299B929C12475
- Restaker Debt Token Implementation: 0x6f2122CeaEe9421996782315fc85dC13FE20Db14
- Price Oracle address: 0xe4558cAab7eF0deEB2340E34343D7c2A08C25A63
- Rate Oracle address: 0x4962b2C3Ab7B5e4674310586f99708dFcdEE785E
- Aave Adapter address: 0x7340C55D8125842Ae3d1647454b968916BC302B7
- Chainlink Adapter address: 0xEAbB135f9373FA4bc97D3B206c98F8E9eE970a37
- Aave Data Provider address: 0x9F267EAbe1Ec5a7cFf777083a7c2e2792505Dde3
- Chainlink Oracle address: 0xD889830d042ACf44b9a941857Ae502d6a9c0A1B4
- Collateral address: 0xDEf61c5c6EF283Ae7BF5f7ee91F74C47eB33ae8F
- Cap Token Adapter address: 0xA10ceFc89397DeeB910A144F695D545F639b3f71
- Staked Cap Adapter address: 0xA12BCC3e4f794a232172143D6b49b4FE1CC140fe
- scUSD Lockbox 0x43C16846322A4647908d16715a86C85cb7500574
- cUSD Lockbox 0x99E7fCd4D8EFEAa8Ec5Beb097F66853d69209fb1


Latest testnet zap deploy:
- Zap Router: 0xC35a456138dE0634357eb47Ba5E74AFE9faE9a98
- Token Manager: 0x34D25ed76876993BdbF1d73507b5C0cd5495A34e
- Permit 2: 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768
