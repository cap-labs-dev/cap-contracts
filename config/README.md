# Config

`cap-v2.json` is the only live file. It is keyed by chain id and holds implementation and infra addresses. Role membership is not listed: a role can have many members, and AccessManager is the source of that.

On Ethereum (`1`), `infra.stablecoin` and `infra.wrapper` are the existing cUSD and stcUSD proxies. `deployer` is the CreateX sender. `timelock` and `multisig` are the accounts that already govern the live system; they are not exclusive holders of any role. Everything else starts as `address(0)` until it is deployed.

v1 files live in `archive/`.

The `11155111` entry is the fresh Sepolia deployment, written by `DeploySepolia.save()`
after it verified the deployed contracts.

Forge writes this file as a single line, so `yarn save:sepolia` reformats it afterwards.
`yarn format:config` restores the layout (chain ids ascending, keys in deploy-struct order,
four-space indent) and `yarn lint:config` checks it; the pre-commit hook and CI run them.
See [SEPOLIA.md](SEPOLIA.md) for simulation, deployment, and role checks.
