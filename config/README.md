# Config

`cap-v2.json` is the only live file. It is keyed by chain id and holds implementation and infra addresses. Role membership is not listed: a role can have many members, and AccessManager is the source of that.

On Ethereum (`1`), `infra.stablecoin` and `infra.wrapper` are the existing cUSD and stcUSD proxies. `deployer` is the CreateX sender. `timelock` and `multisig` are the accounts that already govern the live system; they are not exclusive holders of any role. Everything else starts as `address(0)` until it is deployed.

v1 files live in `archive/`.
