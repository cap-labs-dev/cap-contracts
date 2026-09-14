## CAP Labs Core Contracts

This repository contains the core contracts for the CAP platform. Foundry is used as the development framework.

## Dependencies

Required:
- `git`: [https://git-scm.com/downloads](https://git-scm.com/downloads)
- `yarn`: [https://yarnpkg.com/getting-started](https://yarnpkg.com/getting-started)
- `foundry`: [https://getfoundry.sh/](https://getfoundry.sh/)

Optional:
- `slither`: [https://github.com/crytic/slither](https://github.com/crytic/slither)
- `lcov`: [https://github.com/linux-test-project/lcov](https://github.com/linux-test-project/lcov)

## Setup

### Pull dependencies

```shell
# pull foundry's deps
git pull --recurse-submodules

# install deps
yarn install
```

### Setup environment

Define RPC endpoints in your `~/.foundry/foundry.toml` or as env vars (`ETH_RPC_URL`, and the other keys listed in this repo's `foundry.toml`).

```toml
[rpc_endpoints]
ethereum = "${ETH_RPC_URL}"
```

## Available Scripts

The following scripts are available to run with `yarn`:

### Build and Compile
- `yarn compile`: Build the project using Forge
- `yarn build`: Build the project using Forge (skips test files)
- `yarn test:build`: Build contracts, tests, and scripts with IR optimization

### Testing
- `yarn test`: Run the Foundry suite
- `yarn test:slither`: Run Slither static analysis
- `yarn deploy`: Broadcast `script/Deploy.s.sol`
- `yarn check-roles`: Check AccessManager wiring against `config/cap-v2.json`

### Coverage
- `yarn coverage:forge`: Generate a summary coverage report for `contracts/`
- `yarn coverage:forge:report`: Generate a detailed LCOV coverage report with branch coverage
