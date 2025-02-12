## CAP Labs Core Contracts

This repository contains the core contracts for the CAP platform. Foundry is used as the development framework.

## Dependencies

Required:
- `git`: [https://git-scm.com/downloads](https://git-scm.com/downloads)
- `yarn`: [https://yarnpkg.com/getting-started](https://yarnpkg.com/getting-started)
- `foundry`: [https://getfoundry.sh/](https://getfoundry.sh/)

Optional:
- `slither`: [https://github.com/crytic/slither](https://github.com/crytic/slither)

## Setup

```shell
# pull foundry's deps
git pull --recurse-submodules

# install deps
yarn install
```

## Commands

## Available Scripts

The following scripts are available to run with `yarn`:

### Build and Compile
- `yarn compile`: Build the project using Forge
- `yarn build`: Build the project using Forge (skips test files)
- `yarn test:build`: Build contracts, tests, and scripts with IR optimization

### Testing
- `yarn test`: Run unit tests
- `yarn test:unit`: Run unit tests (excluding slow tests)
- `yarn test:invariants`: Run invariant tests only
- `yarn test:slither`: Run Slither static analysis tool

### Gas Analysis
- `yarn gas:flamegraph`: Generate a flamegraph of gas usage
- `yarn gas:snapshot`: Create a gas snapshot in isolation
- `yarn gas:diff`: Compare gas usage against the last snapshot
- `yarn gas:report`: Generate a gas usage report

### Coverage
- `yarn coverage:forge`: Generate a summary coverage report
- `yarn coverage:forge:report`: Generate a detailed LCOV coverage report with branch coverage

