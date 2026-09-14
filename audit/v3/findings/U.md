# Workstream U — Live-proxy upgrade compatibility (cUSD `0xcCcc…cccC`, stcUSD `0x8888…8888`)

> **Post-verification status (lead, 2026-09-14):** U-1 + U-2 **merged and demoted to High** (`verify/U-1.md`, `verify/U-2.md`: a two-step migrator upgrade recovers the proxies; bare upgrade is an irreversible brick). Report ID R3-H1. U-3 **demoted to Medium** and merged with R3-H1 (`verify/U-3.md`, report R3-M6); U-4 **demoted to Low** as a migration-checklist item (`verify/U-4.md`).


Target: `cap-network` @ `a843c1d`; v1 source `main` @ `695c828` (worktree `scratchpad/v1/main`).
Live state read from Ethereum mainnet at block **25976879** (2026-09-14) via `https://ethereum-rpc.publicnode.com`.
Owner of hypothesis **P22**.

PoC files: `audit/v3/tests/scratch/U/U_LiveUpgrade.t.sol` (mainnet fork of the real proxies, upgrader = the live timelock),
`audit/v3/tests/scratch/U/U_LocalUpgrade.t.sol` (offline: v1 bytecode compiled from the worktree behind fresh ERC1967 proxies),
`audit/v3/tests/scratch/U/StablecoinV2.sol` (verbatim copy of `Stablecoin` + a `reinitializer(2)` used to show what a fix can and cannot repair),
`audit/v3/tests/scratch/U/V1Artifacts.sol` + `artifacts/*.json` (v1 creation bytecode, solc 0.8.28, OZ 5.4.0).
Run: `FOUNDRY_TEST=audit/v3/tests/scratch/U forge test --match-path 'audit/v3/tests/scratch/U/*' -vv`
(`U_RPC` / `U_BLOCK=0` override the fork; the offline suite needs no network).

## 0. Summary

Upgrading the two live proxies to `contracts/cap/Stablecoin.sol` and `contracts/cap/Wrapper.sol` **as the code stands** is a
one-way, unrecoverable event:

1. `Stablecoin.initialize` / `Wrapper.initialize` are plain `initializer` (version 1); both proxies are already at `_initialized == 1`
   (verified on chain) ⇒ the upgrade call data cannot run them (`InvalidInitialization()`), and there is no `reinitializer`.
2. The new code reads OZ namespaces the v1 implementations never wrote: `openzeppelin.storage.AccessManaged` (`authority()`),
   and for cUSD `openzeppelin.storage.ERC4626` (`asset()`, `_underlyingDecimals`). Both are zero on chain. Consequently, after a bare
   upgrade **every `restricted` function including `_authorizeUpgrade` and `setAuthority` reverts forever** (the proxy can never be
   upgraded again), `asset()==address(0)` so every deposit/redeem path reverts, `underlyingDecimals==0` so every preview/convert
   is off by 10^18, and `PremiumVesting.stablecoin()==0` so `claim` reverts. Transfers keep working; 84.88 M cUSD becomes a
   frozen, non-redeemable, non-upgradeable token. stcUSD deposits/withdrawals revert and stcUSD can never `optIn`.
3. Even with a correct reinitializer, the token's economics do not carry over: the live supply is backed by USDC that is **not on
   hand** (3,219 USDC in the contract vs 61.49 M on loan to v1 agents, 18.27 M in a v1 fractional-reserve ERC-4626 vault, plus
   5.12 M wWTGXX as a second basket asset). HEAD has no function that can reach any of it, while `totalAssets()` reports the full
   84.88 M as backing.

Findings: **U-1 Critical**, **U-2 Critical**, **U-3 High**, **U-4 High**, U-5 Low, U-6 Low, U-7 Low, plus informational notes.
All confirmed by failing Foundry tests on a mainnet fork of the real proxies and reproduced offline.

## 1. Which contracts the live addresses run

| Proxy | EIP-1967 implementation (on chain) | v1 implementation name | Source |
|---|---|---|---|
| cUSD `0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC` | `0xa76645E15c267b876999bf7689E0b2C1EE29BFE6` | `capToken` | `config/archive/cap-infra.json` `implems.capToken`; v1 `check-proxy-implem.txt` "Cap Token … Implementation matches" |
| stcUSD `0x88887bE419578051FF9F4eb6C858A951921D8888` | `0x42c0e0ef7C2F35de073F4d6f9c0e4483429c3D31` | `stakedCap` | `config/archive/cap-infra.json` `implems.stakedCap`; "Staked Cap Token … Implementation matches" |

So cUSD runs v1 `contracts/token/CapToken.sol` (`UUPSUpgradeable, Vault` where `Vault is ERC20PermitUpgradeable, PausableUpgradeable,
Access, Minter, FractionalReserve`), and stcUSD runs v1 `contracts/token/StakedCap.sol` (`UUPSUpgradeable, ERC4626Upgradeable,
ERC20PermitUpgradeable, Access`). v1 `contracts/token/Wrapper.sol` (an `ERC20WrapperUpgradeable`, "Wrapped …/w…") is **not** what
stcUSD runs; it is irrelevant to this upgrade. Live implementation code sizes read on the fork (17,006 / 11,056 bytes) match the
worktree builds (17,007 / 11,305 creation → deployed 17,007 for CapToken; the 1-byte and metadata differences are compiler-setting
drift and were not chased — the storage namespaces are what matters and they are dictated by source, not settings).

v1 OpenZeppelin version: `yarn.lock` in the worktree resolves `@openzeppelin/contracts` and `-upgradeable` to **5.4.0** (namespaced
ERC-7201 storage; `Initializable` at `openzeppelin.storage.Initializable`). HEAD uses 5.7.0; the namespace slot constants and struct
member orders of `ERC20`, `ERC4626`, `Initializable`, `AccessManaged`, `Nonces`, `EIP712`, `Pausable` are identical between 5.4.0 and 5.7.0
(checked by reading both trees).

## 2. Storage layouts

`forge inspect … storage-layout` is empty for every contract involved — v1 and HEAD both keep all state in ERC-7201 namespaces or, for
HEAD `Stablecoin`, in a `layout at erc7201("cap.storage.Stablecoin")` base slot. Real outputs:

```
$ forge inspect contracts/token/CapToken.sol:CapToken storage-layout      (v1 worktree build, solc 0.8.28)
╭------+------+------+--------+-------+----------╮
| Name | Type | Slot | Offset | Bytes | Contract |
+================================================+
╰------+------+------+--------+-------+----------╯
(identical empty tables for v1 StakedCap, v1 Wrapper, and HEAD Wrapper; storageLayout JSON: {"storage": [], "types": {}})

$ forge inspect contracts/cap/Stablecoin.sol:Stablecoin storage-layout   (HEAD, solc 0.8.36)
| underlyingDecimals | uint8   | 81785575847109926593853418176707566073488241502930650294254900684737867366400 | 0 | 1  |
| irm                | address | 81785575847109926593853418176707566073488241502930650294254900684737867366400 | 1 | 20 |
| creditBackedSupply | uint256 | ...401 | 0 | 32 |
| badDebt            | uint256 | ...402 | 0 | 32 |
| reserveVault       | address | ...403 | 0 | 20 |
   (base slot = 0xb4d0fed9b23569fd5a9cf7d30ca71c56f00945179421def3b814fede1a2b4000 = cast index-erc7201 cap.storage.Stablecoin)
```

Namespace slots (`cast index-erc7201`, all verified equal to the constants in source):

| Namespace | Slot | Written by v1 CapToken | Written by v1 StakedCap | Read by HEAD Stablecoin | Read by HEAD Wrapper |
|---|---|---|---|---|---|
| `openzeppelin.storage.Initializable` | `0xf0c57e16…6a00` | `_initialized=1` | `_initialized=1` | yes (`initializer` gate) | yes |
| `openzeppelin.storage.ERC20` | `0x52c63247…ce00` | balances/allowances/totalSupply/name "cap USD"/symbol "cUSD" | same, "Staked cap USD"/"stcUSD" | **yes** (all ERC20 state) | **yes** |
| `openzeppelin.storage.ERC4626` (`_asset`, `_underlyingDecimals` packed in one slot) | `0x0773e532…4e00` | **never** (v1 CapToken is not ERC-4626) | `_asset=cUSD`, `_underlyingDecimals=18` (on chain `0x…12cccc…cccc`) | **yes** → asset()=0, dec=0 | yes → cUSD/18, correct |
| `openzeppelin.storage.AccessManaged` (`_authority`) | `0xf3177357…0a00` | never | never | **yes** → 0 | **yes** → 0 |
| `openzeppelin.storage.Nonces` | `0x5ab42ced…bb00` | permit nonces | permit nonces | no (orphaned) | yes (permit kept) |
| `openzeppelin.storage.EIP712` (`_hashedName`, `_hashedVersion`, `_name`, `_version`) | `0xa16a46d9…d100` | "cap USD"/"1" | "Staked cap USD"/"1" | no (orphaned) | yes (domain unchanged) |
| `openzeppelin.storage.Pausable` | `0xcd5ed15c…3300` | `_paused` (live: false) | no | no (orphaned — a paused v1 token would silently un-pause) | no |
| `cap.storage.Access` (`accessControl`) | `0xb413d65c…6b00` | `0x7731129a…c683` (v1 AccessControl proxy) | same | no (orphaned) | no (orphaned) |
| `cap.storage.Vault` (assets set, totalSupplies, totalBorrows, utilizationIndex, lastUpdate, paused, insuranceFund) | `0xe912a1b0…c400` | yes | – | no (orphaned) | – |
| `cap.storage.FractionalReserve` (interestReceiver, loaned, reserve, vault, vaults) | `0x5c48f30a…d100` | yes | – | no (orphaned) | – |
| `cap.storage.Minter` (oracle, redeemFee, fees, whitelist, depositCap) | `0x3b40995b…fe00` | yes | – | no (orphaned) | – |
| `cap.storage.StakedCap` (storedTotal, totalLocked, lastNotify, lockDuration) | `0xc3a6ec7b…7600` | – | yes (storedTotal live `0x42c549…1d07`) | – | no (orphaned) |
| `cap.storage.Stablecoin` (HEAD base slot: underlyingDecimals, irm, creditBackedSupply, badDebt, reserveVault) | `0xb4d0fed9…4000` | never | – | **yes → all zero** | – |
| `cap.storage.ERC7540AsyncRedeem` (requestId, redeemQueue, settledQueue, queueIndex, requestShares, requestController, controllerRequests) | `0x8bbfa7ff…0300` | never | – | yes → zero (fine: empty queue) | – |
| `cap.storage.ERC7540Operator` | `0x984a447e…7200` | never | – | yes → zero (fine) | – |
| `cap.storage.PremiumVesting` (remainder, lastUpdate, perShare, pending, debt, **stablecoin**, optedIn, staked) | `0xcd5f59be…1c00` | never | – | yes → zero; `stablecoin==0` breaks `claim` | – |
| `cap.storage.Wrapper` (HEAD base slot; Wrapper declares no variables) | `0xcefd3d92…f200` | – | never | – | nothing to read |

No slot collisions exist (every namespace hash is distinct), so nothing is *corrupted*; the failure mode is entirely **uninitialised
reads** of `ERC4626`, `AccessManaged`, `cap.storage.Stablecoin` and `cap.storage.PremiumVesting` on cUSD, and of `AccessManaged` on stcUSD.
The only v1 state HEAD *needs* and *gets* is the ERC20 namespace (balances, allowances, supply, name, symbol), plus — for stcUSD only —
the ERC4626 namespace (asset = cUSD, 18 decimals) and the Nonces/EIP712 namespaces (permit domain unchanged).

## 3. Initializer state and post-upgrade behaviour

On chain, both proxies hold `Initializable._initialized == 1` (slot `0xf0c57e16…6a00` → `0x…01`). OZ 5.7.0 `initializer` allows a call only
when `_initialized == 0` (initial setup) or `_initialized == 1 && address(this).code.length == 0` (constructor); a live proxy is neither,
so `Stablecoin.initialize` and `Wrapper.initialize` revert `InvalidInitialization()` whether called inside `upgradeToAndCall` or after.
There is no `reinitializer(n)` anywhere in `contracts/` (`grep -rn reinitializer contracts` → nothing).

### 3a. cUSD after `upgradeToAndCall(Stablecoin, "")` — measured on the fork (test `test_TABLE_2_bareUpgradeBehaviour`)

| Function | Result | Reason |
|---|---|---|
| `name()/symbol()/decimals()/totalSupply()/balanceOf/transfer/approve/transferFrom` | **WORKS** ("cap USD", "cUSD", 18, S unchanged) | ERC20 namespace shared; `decimals()` is `pure 18` |
| `asset()` | **WRONG** → `address(0)` | ERC4626 namespace never written by v1 |
| `underlyingDecimals()`, `irm()`, `reserveVault()`, `creditBackedSupply()`, `badDebt()` | 0 / 0 / 0 / 0 / 0 | `cap.storage.Stablecoin` fresh |
| `authority()` | **WRONG** → `address(0)` (not the v1 AccessControl `0x7731…`, which lives in `cap.storage.Access`) | AccessManaged namespace fresh |
| `stablecoin()` (PremiumVesting) | `address(0)` | namespace fresh |
| `backing()`, `utilizationRate()`, `supplies()` | WORKS (S, 0) | pure arithmetic on shared/zero slots |
| `totalAssets()` | **WRONG-NUMBER**: `84884291` (= S·10^0/10^18) | `underlyingDecimals==0` |
| `previewDeposit(1e6)` | **WRONG-NUMBER**: `1e24` shares for 1 USDC | `mulDiv(1e6, 1e18, 10^0)` |
| `previewMint(1e18)` | **WRONG-NUMBER**: `1` (asset-wei) | `mulDiv(1e18, 10^0, 1e18, Ceil)` |
| `convertToAssets(1e18)` / `convertToShares(1e6)` | 1 / 1e24 | same scaling |
| `unlockedSupply()`, `instantUnlockedSupply()`, `maxRedeem`, `maxInstantRedeem`, `claimableRedeemRequest`, `redeem` (3- and 4-arg), `withdraw`, `instantRedeem`, `instantWithdraw` | **REVERTS** | `IERC20(address(0)).balanceOf(this)` — empty return data fails ABI decoding |
| `deposit`, `mint`, `fund` | **REVERTS** `SafeERC20FailedOperation(0x0)` (`0x5274afe7`) | `safeTransferFrom` on `asset()==0` |
| `requestRedeem(shares)` | **WORKS** (returns id 1; shares move to the contract) | pure ERC20 transfer + queue write — users can lock their cUSD in a queue that can never be claimed |
| `transferRequest`, `setOperator` | WORKS | storage only |
| `optIn()` / `optOut()` | WORKS | storage only |
| `claim(recipient)` | **REVERTS** | `IERC20(stablecoin()==0).balanceOf` |
| `claimable(x)`, `vested()`, `remaining()` | WORKS (0) | reads only |
| `coverBadDebt` | REVERTS `NoBadDebt()` | badDebt 0 (would also hit `irm==0` afterwards) |
| `mintCreditBacked`, `burnCreditBacked`, `fundCreditBacked`, `invest`, `recall`, `setReserveVault`, `recognizeBadDebtIn*` | **REVERTS** `AccessManagedUnauthorized(caller)` (`0x068ca9d8`) for **every** caller incl. the timelock | `AuthorityUtils.canCallWithDelay(address(0), …)`: staticcall to an empty account "succeeds" with empty return ⇒ `immediate=false, delay=0` ⇒ revert |
| `setAuthority(x)` | **REVERTS** for every caller | requires `msg.sender == authority() == address(0)` |
| `upgradeToAndCall(newImpl, …)` | **REVERTS** `AccessManagedUnauthorized(timelock)` | `_authorizeUpgrade` is `restricted` → **proxy permanently bricked** |
| Any call that reaches `IInterestRateModel(irm).updateLiquidityRate()` | REVERTS | `irm==0` (extcodesize check on a no-return call); never reached today because the callers above already revert earlier |
| v1 selectors `mint(address,uint256,uint256,address,uint256)`, `burn`, `redeem(uint256,uint256[],address,uint256)`, `borrow`, `repay`, `investAll`, `divestAll`, `realizeInterest`, `rescueERC20`, `pauseProtocol`, `permit`, `nonces`, `DOMAIN_SEPARATOR` | **REVERTS** (no selector, no fallback) | removed from the ABI. `repay` from the live Lender `0x15622c…` is shown reverting in the table |

### 3b. stcUSD after `upgradeToAndCall(Wrapper, "")` (test `test_TABLE_4_stcusdBehaviour`)

| Function | Result | Reason |
|---|---|---|
| ERC20 views/transfers, `permit`/`nonces`/`DOMAIN_SEPARATOR` | WORKS ("Staked cap USD", "stcUSD", 18; EIP712 domain unchanged) | shared namespaces; HEAD Wrapper keeps ERC20Permit |
| `asset()`, `decimals()` | WORKS (cUSD, 18) | v1 `__ERC4626_init(cUSD)` wrote the same namespace |
| `authority()` | `address(0)` | never written |
| `upgradeToAndCall` (timelock) | **REVERTS** `AccessManagedUnauthorized(timelock)` → **bricked** | `_authorizeUpgrade restricted` |
| `totalAssets()` **if stcUSD is upgraded before cUSD** | **REVERTS** (so do `convertTo*`, `max*`, `preview*`) | v1 cUSD has no `claimable(address)` |
| `totalAssets()` after both upgrades | WORKS but **jumps** from `80,716,092.18` to `80,727,427.64` cUSD (+11,335.46 cUSD = v1 `lockedProfit` 4,673.30 still vesting + 6,662.17 un-notified yield); share price 1.080153974… → 1.080305667… (+0.014 %) | HEAD `totalAssets = balanceOf + claimable(this)`; v1 `storedTotal − lockedProfit` is abandoned |
| `deposit`, `mint`, `withdraw`, `redeem` | **REVERTS** | `IPremiumVesting(cUSD).claim(this)` → `stablecoin()==0` |
| `cUSD.optedIn(stcUSD)` | **false**, `stakedSupply()==0` | `Wrapper.initialize` (the only `optIn()` caller) never runs; nothing else can call `optIn` with `msg.sender == stcUSD` |

### 3c. What a `reinitializer(2)` must set, and what it cannot fix

Demonstrated with `StablecoinV2.migrate(authority, asset, irm, reserveVault)` (`test_TABLE_5_reinitializerLimits`):
`__AccessManaged_init(authority)`; `__PremiumVesting_init(asset, name(), symbol(), address(this))` (re-runs `__ERC20_init` with the values already
in storage so "cap USD"/"cUSD" survive, runs `__ERC4626_init(USDC)` which caches `_underlyingDecimals = 6`, and sets `PremiumVesting.stablecoin`);
`underlyingDecimals = 6`; `irm`; `reserveVault`. After that: `asset()==USDC`, `underlyingDecimals()==6`, deposits at par work, the new AccessManager
governs `_authorizeUpgrade` (the v1 timelock can upgrade again only once it holds ADMIN on the new manager — shown false→true in the log).
For the Wrapper the reinitializer must `__AccessManaged_init` **and call `IPremiumVesting(asset()).optIn()`** — `_underlyingDecimals` (18) and
the EIP712 domain need no change. Both must be executed **inside** `upgradeToAndCall` data (atomic), otherwise anyone can call the
unprotected reinitializer first and pick the authority.

What no reinitializer can fix (see §4): the reserve is not in the contract; the v1 `Vault/FractionalReserve/Minter/Access/Pausable/StakedCap`
state is simply abandoned; `permit` on cUSD is gone (§U-5); the stcUSD share price step (§3b) happens at the moment of upgrade.

## 4. Economic state after upgrade and migration order

Live numbers (block 25976879):

| Quantity | Value |
|---|---|
| cUSD `totalSupply` S | 84,884,291.50 cUSD |
| USDC on hand (`USDC.balanceOf(cUSD)`) | **3,219.19 USDC** |
| v1 `totalSupplies(USDC)` | 79,759,278.00 USDC |
| v1 `totalBorrows(USDC)` (lent to v1 agents through the Lender `0x15622c…`) | **61,486,536.08 USDC** |
| v1 `loaned(USDC)` in fractional-reserve vault `0x3Ed6aa…` ("cap USDC", ERC-4626; `maxWithdraw(cUSD)` = 18,269,522.95) | **18,269,522.95 USDC** |
| second basket asset wWTGXX `0x434558…` (18 dec): on hand 1,716.35, in FR vault `0xb1c1C8…` 5,122,350.35 | **5,124,066.70 wWTGXX** |
| stcUSD supply / v1 `totalAssets` / cUSD held | 74,726,468.68 / 80,716,092.18 / 80,727,427.64 |

Under HEAD after a correct reinitializer (measured): `creditBackedSupply=0`, `badDebt=0`, `backing()=S`, **`totalAssets()` = 84,884,291.50 USDC
(reported)** while **`unlockedSupply()` = 3,219.19 cUSD** (= `quoteWithdraw(balanceOf(this))`), `utilizationRate()=0`, `previewDeposit` at par.
`test_FAIL_5_reportedBackingIsOnHand` fails with `84884291501959 > 3219190527`.

Consequences verified in `test_TABLE_5_reinitializerLimits`:
- A fresh deposit of 1,000 USDC mints 1,000 cUSD at par; bob's `requestRedeem(4,000)` queued afterwards is immediately claimable for the full
  4,000 USDC (3,219 old + 1,000 new less 219 left) — **new deposits are the exit liquidity for the queue**; alice's own `instantRedeem(1,000)` then
  fails. Nobody profits (par in, par out) but every depositor during the window is a lender of last resort to earlier holders, first-come-first-served.
- `recall()` cannot pull the fractional-reserve position: with `reserveVault==0` it reverts; with `setReserveVault(FR vault)` it reverts because
  `recall` speaks the Aera `withdraw(TokenAmount[])` ABI, not ERC-4626. No HEAD function makes cUSD call `IERC4626.redeem` on its own shares,
  and there is no `rescueERC20`. The 18.27 M USDC of FR shares and the 5.12 M wWTGXX (both on hand and in its FR vault) are **unreachable
  after the upgrade**.
- The 61.49 M USDC of v1 agent debt is repaid through `Lender.repay → IVault(cUSD).repay(asset, amount)` (`v1 BorrowLogic.sol:150`); that selector
  no longer exists, so **v1 borrowers cannot repay after the upgrade** (a plain USDC transfer to the proxy would raise `unlockedSupply`, but the
  Lender's debt-token accounting and liquidations are dead).
- v1 `Pausable` is ignored: if the migration relies on `pauseProtocol()` (held by the deployer EOA, the multisig and `0x5143…`) to freeze v1 before
  upgrading, HEAD un-pauses implicitly; conversely HEAD has no pause at all.

Migration order the code forces (all before, or atomically with, the cUSD upgrade; none of it is scripted in `script/`):
1. Repay or liquidate all v1 agent debt (`totalBorrows(USDC) → 0`) and realise interest; `divestAll(USDC)` and `divestAll(wWTGXX)`
   (role holder: multisig `0xb8FC…`) so every asset is on hand. Remove wWTGXX from the basket: HEAD is single-asset USDC — the wWTGXX
   backing must be swapped to USDC or its cUSD share burned via v1 `burn/redeem` before the upgrade, otherwise its holders' claim is
   silently re-denominated in USDC that is not there.
2. Pause v1 (`pauseProtocol`) to stop mint/burn/borrow racing the upgrade, accepting that the pause bit is dropped by HEAD.
3. Deploy the new AccessManager, IRM (pointing at `0xcCcc…`), Registry etc.; grant ADMIN to the timelock/multisig on the new manager.
4. Timelock (`0xD8236031…`, 1-day delay, proposer = multisig `0xb8FC…` 3/5) executes `cUSD.upgradeToAndCall(StablecoinImpl, migrate(...))`
   **then in the same batch** `stcUSD.upgradeToAndCall(WrapperImpl, migrate(...))` (stcUSD first would leave stcUSD reverting until cUSD follows).
   With the reinitializer inside the call data there is no window in which the unprotected initializer can be front-run.
5. Only then let new deposits in. Expect `unlockedSupply()` = whatever USDC step 1 brought on hand; every cUSD holder can redeem at par only up
   to that amount, FIFO.

## 5. Proxy admin / upgrade authority

- Both proxies are plain `ERC1967Proxy` (admin slot `0xb531…6103` = 0) — UUPS, so the implementation's `_authorizeUpgrade` is the only gate.
- v1: `CapToken._authorizeUpgrade` and `StakedCap._authorizeUpgrade` are `checkAccess(bytes4(0))` → `IAccessControl(0x7731…).checkAccess(0x00000000, proxy, caller)`
  → OZ `AccessControlEnumerable` role `bytes32(bytes4(0)) | uint160(proxy)`. On chain each role has exactly one member: **`0xD8236031d8279d82E615aF2BFab5FC0127A329ab`**,
  a `TimelockController` with `getMinDelay() == 86400`; PROPOSER/CANCELLER = Safe `0xb8FC49…` (5 owners, threshold 3), EXECUTOR = the Safe and the deployer
  EOA `0xc1ab5a…`; open executor (`address(0)`) is **not** set. DEFAULT_ADMIN of the v1 AccessControl is the same timelock.
- HEAD: `_authorizeUpgrade` is `restricted` on both. After the upgrade `authority()` is `address(0)`, the v1 AccessControl at `0x7731…` is *not*
  consulted (different namespace) and would not implement `canCall` anyway ⇒ `AccessManagedUnauthorized` for everyone, forever (U-2).
- `config/cap-v2.json` labels `0x7731129a…c683` as `"timelock"` and `0xb8FC49…` as `"multisig"`. `0x7731…` is the **v1 AccessControl proxy**
  (329-byte proxy, `getMinDelay()` reverts); the real timelock is `0xD8236031…` (13,103 bytes, `getMinDelay()==86400`). `script/manage/CheckRoles.s.sol:323`
  would print the wrong label (U-6).

## 6. On-chain verification (commands and outputs)

Endpoints tried: `ethereum-rpc.publicnode.com` ✔ (25976868), `eth.drpc.org` ✔, `eth.llamarpc.com` (HTML), `cloudflare-eth.com` (-32046),
`rpc.ankr.com/eth` (401), `1rpc.io/eth` (503). Everything below uses publicnode.

```
$ cast block-number --rpc-url https://ethereum-rpc.publicnode.com
25976879
$ C=0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC; S=0x88887bE419578051FF9F4eb6C858A951921D8888
$ cast storage $C 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc   # EIP-1967 impl
0x000000000000000000000000a76645e15c267b876999bf7689e0b2c1ee29bfe6
$ cast storage $C 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103   # EIP-1967 admin
0x0000000000000000000000000000000000000000000000000000000000000000
$ cast storage $C 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00   # openzeppelin.storage.Initializable
0x0000000000000000000000000000000000000000000000000000000000000001
$ cast storage $C 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00   # openzeppelin.storage.ERC4626
0x0000000000000000000000000000000000000000000000000000000000000000
$ cast storage $C 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00   # openzeppelin.storage.AccessManaged
0x0000000000000000000000000000000000000000000000000000000000000000
$ cast storage $C 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00   # cap.storage.Access
0x0000000000000000000000007731129a10d51e18cde607c5c115f26503d2c683
$ cast storage $C 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300   # openzeppelin.storage.Pausable
0x0000000000000000000000000000000000000000000000000000000000000000
$ cast storage $C 0xcd5f59be90fcb6cd1e07c030ed45d88d80c86b8efb27e0d1fc4732fdedcd1c00   # cap.storage.PremiumVesting
0x0000000000000000000000000000000000000000000000000000000000000000
$ cast call $C "name()(string)"; "symbol()(string)"; "decimals()(uint8)"; "totalSupply()(uint256)"
"cap USD"   "cUSD"   18   84884291501959874862084607 [8.488e25]
$ cast call $C "assets()(address[])"
[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x434558CB1EBe9950e8A66f1ef8A15A473Dce7D8c]
$ cast call 0x434558CB… "name()(string)" "symbol()(string)" "decimals()(uint8)"
"Wrapped WisdomTree Government Money Market Digital Fund"  "wWTGXX"  18
$ cast call $C "totalSupplies(address)(uint256)" USDC      → 79759277997441
$ cast call $C "totalBorrows(address)(uint256)" USDC       → 61486536084511
$ cast call $C "availableBalance(address)(uint256)" USDC   → 18272741912930
$ cast call $C "loaned(address)(uint256)" USDC             → 18269522954901
$ cast call $C "reserve(address)(uint256)" USDC            → 0
$ cast call $C "utilization(address)(uint256)" USDC        → 770901362553504265507198014 (77.09 %)
$ cast call $C "fractionalReserveVault(address)(address)" USDC → 0x3Ed6aa32c930253fc990dE58fF882B9186cd0072
$ cast call $C "paused()(bool)"                            → false
$ cast call USDC "balanceOf(address)(uint256)" $C          → 3219190527
$ cast call $C "totalSupplies/loaned/…" wWTGXX             → 5124039284977096693634085 / 5122322930759875940705103 ; on hand 1716354217220752928982
$ cast call 0x3Ed6aa… "name()(string)" "asset()(address)" "balanceOf(address)(uint256)" $C "maxWithdraw(address)(uint256)" $C
"cap USDC"  USDC  17523486660209  18269522954902
$ cast call 0xb1c1C8… …   → "cap wWGTXX"  wWTGXX  4998196652305333427807371  5122350587251531984185726
$ cast storage $S <impl slot>            → 0x…42c0e0ef7c2f35de073f4d6f9c0e4483429c3d31
$ cast storage $S <Initializable>        → 0x…01
$ cast storage $S <ERC4626>              → 0x000000000000000000000012cccc62962d17b8914c62d74ffb843d73b2a3cccc   (decimals 0x12=18 | asset cUSD)
$ cast storage $S <AccessManaged>        → 0x…00
$ cast storage $S <cap.storage.Access>   → 0x…7731129a10d51e18cde607c5c115f26503d2c683
$ cast storage $S 0xc3a6ec7b…7600 (cap.storage.StakedCap.storedTotal) → 0x…42c54976edcfae372f1d07 = 80720765473742239547989255
$ cast call $S "name()" "symbol()" "decimals()" "totalSupply()" "totalAssets()" "totalLocked()" "lastNotify()" "lockDuration()" "lockedProfit()"
"Staked cap USD" "stcUSD" 18 74726468678648535732364880 80716095828252641574640082 13143646413254655243961 1789347467 86400 4669645489597973349173
$ cast call $C "balanceOf(address)(uint256)" $S            → 80727427641338800260008536
$ AC=0x7731129a10d51e18cDE607C5C115F26503D2c683
$ cast storage $AC <impl slot>                              → 0x…6681eb184c876d74ea3ddfae0ecee0c9c0f84bc1  (= archive implems.accessControl)
$ cast call $AC "getRoleMemberCount(bytes32)(uint256)" 0x000000000000000000000000cccc62962d17b8914c62d74ffb843d73b2a3cccc → 1
$ cast call $AC "getRoleMember(bytes32,uint256)(address)" <same> 0                     → 0xD8236031d8279d82E615aF2BFab5FC0127A329ab
$ … role(bytes4(0), stcUSD) → 1 member: 0xD8236031d8279d82E615aF2BFab5FC0127A329ab ; DEFAULT_ADMIN_ROLE → 1 member: same
$ role(repay, cUSD) → 0x15622c3dbbc5614E6DFa9446603c1779647f01FC (Lender); role(borrow, cUSD) → same;
  role(divestAll, cUSD) → 0xb8FC49402dF3ee4f8587268FB89fda4d621a8793; role(rescueERC20, cUSD) → 0xb8FC…;
  role(pauseProtocol, cUSD) → 0xc1ab5a…, 0xb8FC…, 0x5143957cfCA5c683a2b6B4Bdb715a9d9aCF6d77a
$ cast call 0xD8236031… "getMinDelay()(uint256)" → 86400 ; cast code 0x7731… | wc -c → 329 (proxy) ; 0xb8FC… → 345 (Safe proxy)
$ timelock.hasRole(PROPOSER_ROLE, 0xb8FC…)=true  EXECUTOR_ROLE: 0xb8FC… true, 0xc1ab5a… true, address(0) false  CANCELLER: 0xb8FC… true
$ Safe 0xb8FC…: getOwners() = [0xDD30a4…, 0xdf466F…, 0x7c29F6…, 0x62D0b3…, 0xA62f87…]  getThreshold() = 3
```

## 7. PoC output

`FOUNDRY_TEST=audit/v3/tests/scratch/U forge test --match-path 'audit/v3/tests/scratch/U/*' -vv` (fork pinned at 25976879; full log in
`scratchpad/U/final.log`):

```
Ran 14 tests for audit/v3/tests/scratch/U/U_LiveUpgrade.t.sol:U_LiveUpgrade
[FAIL: InvalidInitialization()] test_FAIL_1_initializeRunsOnLiveCusd() (gas: 4531060)
[FAIL: InvalidInitialization()] test_FAIL_1b_initializeRunsOnLiveStcusd() (gas: 2228018)
[FAIL: asset: 0x0000000000000000000000000000000000000000 != 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] test_FAIL_2_assetAndDecimalsSurvive() (gas: 41769)
[FAIL: EvmError: Revert] test_FAIL_2b_holderCanRedeem() (gas: 53227)
[FAIL: authority should be the live access control: 0x0000000000000000000000000000000000000000 != 0x7731129a10d51e18cDE607C5C115F26503D2c683] test_FAIL_3_proxyStillUpgradeable() (gas: 41816)
[FAIL: stcUSD opted in] test_FAIL_4_wrapperOptedIn() (gas: 65493)
[FAIL: EvmError: Revert] test_FAIL_4b_wrapperDepositWorks() (gas: 145344)
[FAIL: totalAssets exceeds USDC on hand: 84884291501959 > 3219190527] test_FAIL_5_reportedBackingIsOnHand() (gas: 9224903)
[PASS] test_TABLE_0_liveState() (gas: 553879)
[PASS] test_TABLE_1_initializeRevertSelectors() (gas: 4571228)
[PASS] test_TABLE_2_bareUpgradeBehaviour() (gas: 796374)
Logs:
  == cUSD after upgradeToAndCall(Stablecoin, "") by the v1 timelock ==
    name() cap USD / symbol() cUSD / decimals() 18 / totalSupply() unchanged true / balanceOf(alice) 10000000000000000000000
    asset() 0x0000000000000000000000000000000000000000
    underlyingDecimals() 0 / irm() 0x0 / reserveVault() 0x0 / authority() 0x0 / stablecoin() [PremiumVesting] 0x0
    creditBackedSupply() 0 / badDebt() 0 / backing() 84884291501959874862084607 / utilizationRate() 0
    totalAssets() [WRONG: S/1e18] 84884291
    previewDeposit(1e6 USDC) [WRONG] 1000000000000000000000000
    previewMint(1e18 cUSD) [WRONG] 1
    convertToAssets(1e18) [WRONG] 1 / convertToShares(1e6) [WRONG] 1000000000000000000000000
    unlockedSupply() -> REVERTS / instantUnlockedSupply() -> REVERTS / maxRedeem(alice) -> REVERTS / maxInstantRedeem(alice) -> REVERTS
    claimable(stcUSD) -> WORKS 0 / vested() -> WORKS 0
    deposit(1000e6, alice) -> REVERTS 0x5274afe7… / mint(1e18, alice) -> REVERTS 0x5274afe7… / fund(1e6) -> REVERTS 0x5274afe7…
    instantRedeem(1e18) -> REVERTS / instantWithdraw(1) -> REVERTS
    requestRedeem(5000e18) [shares leave alice] -> WORKS 1 / balanceOf(alice) after request -> WORKS 5000000000000000000000
    redeem(1,alice,alice) 3-arg -> REVERTS / redeem(1,1,alice,alice) 4-arg -> REVERTS / claimableRedeemRequest(1,alice) -> REVERTS
    transfer(bob, 1e18) -> WORKS 1 / approve(bob, 1e18) -> WORKS 1 / optIn() -> WORKS / claim(alice) -> REVERTS
    coverBadDebt(1) -> REVERTS 0x38b13f8d… (NoBadDebt)
    permit(...) [v1 selector, gone] -> REVERTS / nonces(alice) -> REVERTS / DOMAIN_SEPARATOR() -> REVERTS
    mintCreditBacked (restricted, timelock) -> REVERTS 0x068ca9d8… / setReserveVault -> REVERTS 0x068ca9d8…
    recognizeBadDebtInReserve -> REVERTS 0x068ca9d8… / invest(1) -> REVERTS 0x068ca9d8…
    setAuthority(am) (timelock) -> REVERTS 0x068ca9d8…
    upgradeToAndCall(again) (timelock) [BRICKED] -> REVERTS 0x068ca9d8…
    divestAll(USDC) [v1 selector, gone] -> REVERTS / Lender -> repay(USDC, 1) [v1 selector, gone] -> REVERTS
[PASS] test_TABLE_3_upgradeBrickedSelectors() (gas: 86496)
Logs:  cUSD and stcUSD: second upgradeToAndCall and setAuthority revert AccessManagedUnauthorized(timelock)
[PASS] test_TABLE_4_stcusdBehaviour() (gas: 363146)
Logs:
  == stcUSD upgraded BEFORE cUSD ==
    totalAssets() [v1 cUSD has no claimable()] -> REVERTS / convertToAssets(1e18) -> REVERTS / maxWithdraw(alice) -> REVERTS
  == both upgraded (bare) ==
    stcUSD totalAssets before upgrade (v1) 80716092177239749003902514
    stcUSD totalAssets after upgrade 80727427641338800260008536  (= cUSD.balanceOf(stcUSD))
    jump (cUSD, released lockedProfit + un-notified) 11335464099051256106022
    share price before 1080153974950279137 / after 1080305667707872138
    cUSD.optedIn(stcUSD) false / cUSD.stakedSupply() 0 / stcUSD.authority() 0x0
    stcUSD.deposit(1e18) -> REVERTS / stcUSD.mint(1e18) -> REVERTS
    cUSD.optIn() as stcUSD [no caller exists on-chain] -> WORKS   (only reachable with vm.prank)
    stcUSD.permit(...) [kept: HEAD Wrapper has ERC20Permit] -> WORKS 0
[PASS] test_TABLE_5_reinitializerLimits() (gas: 10307301)
Logs:
  == cUSD upgraded with a reinitializer(2) that sets authority/asset/decimals/irm/stablecoin ==
    asset() USDC / underlyingDecimals() 6 / authority() <new AccessManager> / irm() <new IRM> / name()/symbol() preserved cap USD cUSD
    totalSupply S 84884291501959874862084607
    totalAssets() REPORTED (USDC, 6-dec) 84884291501959
    USDC actually on hand 3219190527
    unlockedSupply() (cUSD redeemable right now) 3219190527000000000000
    USDC on loan to v1 agents (v1 view, snapshot pre-upgrade) 61486536084511
    USDC in v1 FR vault (shares held by cUSD, no HEAD path to redeem) 18269522954902
    wWTGXX on hand + FR vault (no HEAD path at all) 1716354217220752928982 5122350347355029149266261
    alice deposit(1000 USDC) -> cUSD 1000000000000000000000
    bob requestRedeem(4000 cUSD) id 1 / bob claimableRedeemRequest 4000000000000000000000
    bob redeemed USDC 4000000000 / USDC left on hand 219190527 / unlockedSupply() now 219190527000000000000
    alice instantRedeem(1000 cUSD) ok? false
    recall(1) with reserveVault=0 -> REVERTS / recall(1) with reserveVault=FR_USDC (ERC4626, not Aera) -> REVERTS
    timelock upgrade again ok? (ADMIN of the new AccessManager needed) false / ... after granting ADMIN to the timelock ok? true
Suite result: FAILED. 6 passed; 8 failed; 0 skipped

Ran 11 tests for audit/v3/tests/scratch/U/U_LocalUpgrade.t.sol:U_LocalUpgrade      (offline, v1 bytecode from the worktree)
[FAIL: InvalidInitialization()] test_FAIL_1_initializeRunsOnUpgradedProxy() (gas: 40522)
[FAIL: asset: 0x0000000000000000000000000000000000000000 != 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f] test_FAIL_2_assetSurvives() (gas: 35905)
[FAIL: EvmError: Revert] test_FAIL_2b_holderCanRedeem() (gas: 42748)
[FAIL: AccessManagedUnauthorized(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496)] test_FAIL_3_proxyStillUpgradeable() (gas: 32349)
[FAIL: stcUSD opted in] test_FAIL_4_wrapperOptedIn() (gas: 58142)
[FAIL: EvmError: Revert] test_FAIL_4b_wrapperDepositWorks() (gas: 134061)
[PASS] test_TABLE_2_bareUpgrade() … alice requestRedeem(4000) ok? true / claimableRedeemRequest ok? false / nonces(alice) ok? [permit removed] false
[PASS] test_TABLE_4_wrapper() … totalAssets before (v1) 5025e18, lockedProfit 75e18, after 5100e18, jump == lockedProfit? true, optedIn false, redeem ok? false
[PASS] test_TABLE_v1State() / test_initializeRevertsInvalidInitialization() / test_upgradeBrickedSelectors()
Suite result: FAILED. 5 passed; 6 failed; 0 skipped
```

Offline approach: the v1 closure (`CapToken`, `StakedCap`, `Vault`, `FractionalReserve`, `Minter`, `Access`, storage utils, interfaces, the three
external libraries) was copied into `scratchpad/U/v1proj`, built with solc 0.8.28 / optimizer 200 / OZ 5.4.0 (`npm install` in the scratch project
only; the main repo's `node_modules` was not touched). `CapToken` links `VaultLogic`, `MinterLogic`, `FractionalReserveLogic`; the bytecode is
linked in `V1Artifacts.sol` against fixed addresses `0x1111…01/02/03` at which the test `vm.etch`es the library runtime. Balances are written into
the OZ ERC20 namespace with `vm.store`; the v1 `AccessControl` is replaced by a stub whose `checkAccess` admits the deployer.

## 8. Findings

### [CRITICAL] U-1 — The live proxies cannot be initialised into the new code: `initialize` is `initializer`-gated, no `reinitializer` exists, and every slot the new code depends on is left at zero
**Location:** `contracts/cap/Stablecoin.sol:L53-L75` (`initialize`), `contracts/cap/Wrapper.sol:L37-L47` (`initialize`); consumers `Stablecoin.sol:L184-L194` (`unlockedSupply`), `L200-L224` (`totalAssets/previewDeposit/previewMint`), `L236-L290` (`_convertTo*`), `contracts/utils/PremiumVesting.sol:L142-L158` (`claim`), OZ `ERC4626Upgradeable.asset()`
**Impact:** After `upgradeToAndCall(Stablecoin, "")` on `0xcCcc…` the token keeps balances and transfers but `asset()==0`, `underlyingDecimals==0`,
`irm==0`, `stablecoin()==0`: every deposit/mint/fund/redeem/withdraw/claim path reverts, every preview is off by 10^18 (`previewDeposit(1 USDC)`
= 10^24 cUSD, `previewMint(1 cUSD)` = 1 asset-wei, `totalAssets()` = 84,884,291 asset-wei), `requestRedeem` still succeeds and strands the caller's
cUSD in a queue that can never settle. stcUSD deposits/withdrawals revert because `claim` reverts. All 84.88 M cUSD and 74.7 M stcUSD are
affected; combined with U-2 the state is permanent.
**Likelihood:** Certain if the upgrade is executed as planned (Matt: the live proxies *will* be upgraded to this code). No attacker needed;
`script/` contains no upgrade/migration path for the existing proxies at all (`DeployInfra.sol:L95-L112` deploys *fresh* CREATE3 proxies).
**Exploit path:** 1. Timelock executes `cUSD.upgradeToAndCall(StablecoinImpl, initializeCalldata)` → `InvalidInitialization()`; or with empty data → succeeds.
2. Any holder calls `instantRedeem`/`redeem`/`deposit` → revert (`test_FAIL_2b`). 3. Holder calls `requestRedeem` → shares leave the wallet, `claimableRedeemRequest` reverts forever.
**Proof:** `test_FAIL_1_initializeRunsOnLiveCusd`, `test_FAIL_1b_initializeRunsOnLiveStcusd`, `test_FAIL_2_assetAndDecimalsSurvive`, `test_FAIL_2b_holderCanRedeem`
(fork) and the same names in `U_LocalUpgrade.t.sol` (offline); table in `test_TABLE_2_bareUpgradeBehaviour` (§7).
**Recommendation:** Add a version-2 entry point on both contracts, e.g. `function migrate(address authority, address asset, address irm, address reserveVault) external reinitializer(2)`
doing `__AccessManaged_init`, `__PremiumVesting_init(asset, name(), symbol(), address(this))` (keeps "cap USD"/"cUSD", writes ERC4626 `_asset`/`_underlyingDecimals`),
`underlyingDecimals = asset.decimals()` with the same `UnsupportedDecimals` check, `irm`, `reserveVault`; and on `Wrapper` `migrate(address authority) reinitializer(2)` doing
`__AccessManaged_init` **and** `IPremiumVesting(asset()).optIn()`. Execute them **inside** `upgradeToAndCall` (atomic — the reinitializer has no
access control by design and would otherwise be front-runnable). Keep `initialize` for fresh deployments. Add a fork test to `test/` that upgrades
the real proxies and checks `asset()`, `authority()`, `optedIn(wrapper)`, a deposit and a redeem. Second-order: `__ERC20_init` inside the reinitializer
re-writes name/symbol — pass the stored values; `_underlyingDecimals` becomes 6 (USDC) which is what the rest of the code assumes.
**Invariant broken:** I26 (`redeem(maxRedeem(a))` never reverts — `maxRedeem` itself reverts); I34 (`balanceOf(stablecoin) ≥ redemptionQueue()+remaining()` is un-evaluable, `asset()==0`).

### [CRITICAL] U-2 — After the upgrade `authority()` is `address(0)`: `_authorizeUpgrade`, `setAuthority` and every `restricted` function revert for everyone, permanently bricking both proxies
**Location:** `contracts/cap/Stablecoin.sol:L333` and `contracts/cap/Wrapper.sol:L102` (`_authorizeUpgrade … restricted`); OZ `AccessManagedUpgradeable._checkCanCall` + `AuthorityUtils.canCallWithDelay` (staticcall to an empty account returns success with no data ⇒ `immediate=false, delay=0` ⇒ `AccessManagedUnauthorized`); `setAuthority` requires `msg.sender == authority()`.
**Impact:** Once the bare upgrade lands, no second upgrade, no `setAuthority`, no `mintCreditBacked`/`invest`/`recall`/`setReserveVault`/`recognizeBadDebt*` can ever succeed on cUSD, and no second upgrade on stcUSD. The defects of U-1 therefore cannot be patched afterwards: 84.88 M cUSD is frozen in a non-redeemable, non-upgradeable token. The v1 `AccessControl` (`0x7731…`) that governs today lives in `cap.storage.Access` and is never consulted by HEAD.
**Likelihood:** Certain on a bare upgrade; also certain if a reinitializer is added but not executed atomically in the same `upgradeToAndCall` (a plain `upgradeTo` first would brick before the second tx). Cost to the protocol: total; no attacker needed.
**Exploit path:** 1. Timelock: `cUSD.upgradeToAndCall(impl, "")` (succeeds under v1 `checkAccess(bytes4(0))`). 2. Timelock (or anyone): `cUSD.upgradeToAndCall(fixedImpl, …)` → `AccessManagedUnauthorized(0xD823…)`. 3. `setAuthority(0x7731…)` → same revert. There is no other writer of the `AccessManaged` namespace.
**Proof:** `test_FAIL_3_proxyStillUpgradeable` (fork; fails with authority `0x0 != 0x7731…`), `test_TABLE_3_upgradeBrickedSelectors` (both proxies, exact revert data), offline `test_FAIL_3_proxyStillUpgradeable` / `test_upgradeBrickedSelectors`.
**Recommendation:** As U-1 (reinitializer that calls `__AccessManaged_init` executed inside `upgradeToAndCall`). Additionally make `_authorizeUpgrade` tolerant of the migration window, e.g. `if (authority() == address(0)) { require(IAccessControl(v1AccessSlot).checkAccess(bytes4(0), address(this), msg.sender)); } else _checkCanCall(...)` — or simpler, rehearse the exact timelock batch on a fork (this test) as a release gate. Second-order: whoever holds ADMIN on the new AccessManager becomes the upgrader; make sure the timelock is granted it before the batch or the timelock loses upgrade rights (shown in `test_TABLE_5`: false until granted).
**Invariant broken:** none listed; new invariant N-U1 below.

### [HIGH] U-3 — stcUSD is permanently opted out of premium after the upgrade; `Wrapper.initialize`'s `optIn()` is the only path and it never runs
**Location:** `contracts/cap/Wrapper.sol:L46` (`IPremiumVesting(address(asset())).optIn()` inside `initialize`), `contracts/utils/PremiumVesting.sol:L114-L124` (`optIn` keyed on `msg.sender`), `Wrapper.sol:L50-L52` (`totalAssets = balance + claimable(this)`)
**Impact:** With `optedIn[stcUSD]==false` and `staked==0`, every `fund`/`fundCreditBacked` premium on cUSD is frozen (`_accrue` with `supply==0` only bumps `lastUpdate`) or, once any other holder opts in, flows entirely to them: the 74.7 M stcUSD holders (95 % of cUSD supply) earn nothing from the new system, forever, because no contract function lets stcUSD be `msg.sender` of `optIn`. Separately, at the upgrade instant `Wrapper.totalAssets()` switches from `storedTotal − lockedProfit` to `balanceOf` and steps up by 11,335.46 cUSD (4,673 still-vesting + 6,662 un-notified): a one-off +0.014 % that a depositor can capture by entering just before the batch (≈ 1.4 cUSD per 10,000 — negligible, noted for completeness). If stcUSD is upgraded before cUSD, `totalAssets` reverts (v1 cUSD lacks `claimable`).
**Likelihood:** Certain on upgrade (bare or with a cUSD-only reinitializer); opt-in requires a Wrapper-side reinitializer — none exists.
**Exploit path (value diversion):** 1. Both proxies upgraded with a cUSD reinitializer but no Wrapper `optIn`. 2. Any cUSD holder H calls `optIn()` (works — table). 3. Markets pay premium via `fundCreditBacked` → 100 % accrues to H's balance share of `staked` (only H is staked) while stcUSD (80.7 M cUSD) earns 0. Net: every premium dollar to whoever opted in first; stcUSD holders lose the entire yield stream.
**Proof:** `test_FAIL_4_wrapperOptedIn` (fork and offline) fails with "stcUSD opted in"; `test_FAIL_4b_wrapperDepositWorks` fails (deposit reverts); `test_TABLE_4_stcusdBehaviour` prints `cUSD.optedIn(stcUSD) false`, `stakedSupply() 0`, the totalAssets step, and the order-dependency reverts.
**Recommendation:** `Wrapper.migrate(address authority) external reinitializer(2) { __AccessManaged_init(authority); IPremiumVesting(address(asset())).optIn(); }` executed in the same batch **after** cUSD. Consider also a permissionless `Wrapper.optIn()` passthrough (idempotent) as a safety valve. Decide explicitly whether the 11.3 k cUSD of in-flight v1 yield should be released at once (current behaviour) or re-vested (call v1 `notify()` and wait `lockDuration` before upgrading so `lockedProfit→0`).
**Invariant broken:** P18 family (opt-in forfeiture) — here forced on the largest holder.

### [HIGH] U-4 — The migrated token reports full backing while the reserve is not in the contract and cannot be reached by any new function (61.5 M USDC on loan to v1 agents, 18.3 M USDC in a v1 ERC-4626 reserve, 5.1 M wWTGXX second asset)
**Location:** `contracts/cap/Stablecoin.sol:L184-L194` (`unlockedSupply` = min(supply − locked, `_quoteWithdraw(balanceOf(this))`)), `L200-L202` (`totalAssets = backing()` scaled), `L102-L118` (`invest`/`recall` speak only the Aera ABI), absence of any rescue/`redeem`-on-external-vault/`repay` entry point; v1 `contracts/vault/Vault.sol` (`repay`, `divestAll`, `rescueERC20`, multi-asset basket).
**Impact:** Post-upgrade (with a correct reinitializer) `totalAssets()` = 84,884,291.50 USDC and `backing()` = S, but `unlockedSupply()` = 3,219.19 cUSD. Holders can redeem at par only up to what is on hand, FIFO; new deposits become other people's exit liquidity. Whatever is not repaid/divested before the upgrade is unrecoverable through the new code: FR-vault shares (`0x3Ed6aa…` 17.5 T shares → 18.27 M USDC; `0xb1c1C8…` → 5.12 M wWTGXX) sit at the proxy with no function to redeem them; v1 agents cannot `repay` (selector gone) so 61.49 M USDC of loans have no contractual repayment path; wWTGXX holders' claim is re-denominated in USDC that does not exist. This is the "system reports itself covered while depositors cannot redeem" case.
**Likelihood:** Conditional on migration sequencing, which nothing in the repo enforces or scripts. Given the live utilisation (77 %, 61.5 M borrowed) a clean wind-down before the batch is a multi-party operation with a 1-day timelock; any residual at execution time is permanently stranded.
**Exploit path (loss without attacker):** 1. Upgrade with reinitializer at today's state. 2. Alice deposits 1,000 USDC (par). 3. Bob (older holder) `requestRedeem(4,000)` → immediately claimable → pays out Alice's 1,000 + 3,000 of the old 3,219 (fork log). 4. Alice cannot redeem her own 1,000 (`instantRedeem` fails; `unlockedSupply()` = 219). 5. `recall()` cannot pull the FR position under any `reserveVault` setting (both reverts logged); v1 Lender `repay` reverts.
**Proof:** `test_FAIL_5_reportedBackingIsOnHand` fails `84884291501959 > 3219190527`; `test_TABLE_5_reinitializerLimits` (all steps above logged); on-chain reads in §6.
**Recommendation:** Treat the migration as a state transfer, not an upgrade: (a) in v1, repay/liquidate all debt, `divestAll` both assets, unwind wWTGXX to USDC (or burn its cUSD via v1 `redeem`), `pauseProtocol`; (b) prove on a fork that `USDC.balanceOf(cUSD)·10^12 == totalSupply()` (or record the shortfall as `badDebt`/`creditBackedSupply` in the reinitializer so `unlockedSupply`/`backing` are honest); (c) give the new `Stablecoin` a governance-only escape hatch for leftover v1 positions (`rescue(token, to)` restricted to GOVERNOR, or an `IERC4626.redeem` passthrough for the FR vaults) — its second-order cost is a trusted sweep power, so gate it behind the timelock and log it. Alternatively deploy fresh proxies and migrate balances 1:1 (what `DeployInfra` already does), which sidesteps every item in this file.
**Invariant broken:** I34; the plan's "un-writable" note (`totalAssets` vs USDC on hand) is exactly what fails here.

### [LOW] U-5 — cUSD loses `permit`/`nonces`/`DOMAIN_SEPARATOR` (HEAD `Stablecoin` has no ERC20Permit); EIP712 and Nonces namespaces are orphaned
**Location:** `contracts/cap/Stablecoin.sol:L22-L28` (inheritance list: `AccessManagedUpgradeable, PremiumVesting, UUPSUpgradeable` only); v1 `Vault is ERC20PermitUpgradeable`.
**Impact:** Any integration signing cUSD permits (v1 zaps/lockboxes, Permit2-style routers, wallets) breaks after the upgrade; the ERC20 interface visibly shrinks on a token with 84.88 M supply. No funds at risk; stcUSD keeps permit with an unchanged domain.
**Likelihood:** Certain on upgrade.
**Exploit path:** n/a (breaking change).
**Proof:** `test_TABLE_2_bareUpgradeBehaviour`: `permit(...) -> REVERTS`, `nonces -> REVERTS`, `DOMAIN_SEPARATOR -> REVERTS`; offline `nonces(alice) ok? false` after `0` before.
**Recommendation:** Inherit `ERC20PermitUpgradeable` in `Stablecoin` (the v1 EIP712 name "cap USD"/version "1" and nonces are already in storage and would be picked up unchanged) or announce the removal.
**Invariant broken:** none.

### [LOW] U-6 — `config/cap-v2.json` mislabels the v1 AccessControl proxy as the timelock; the real upgrader is `0xD8236031…`
**Location:** `config/cap-v2.json` (`"timelock": "0x7731129a10d51e18cDE607C5C115F26503D2c683"`), `script/manage/CheckRoles.s.sol:L323-L324`, `config/README.md`.
**Impact:** Role reports and any migration batch built from the config would target the wrong address: `0x7731…` is the v1 `AccessControl` UUPS proxy (impl `0x6681EB…`, matches `config/archive/cap-infra.json`), the actual `TimelockController` (1-day delay; proposer/canceller = Safe `0xb8FC…` 3-of-5; executors = the Safe and deployer EOA `0xc1ab5a…`) is `0xD8236031d8279d82E615aF2BFab5FC0127A329ab` (`config/archive/cap-infra.json` `infra.timelock`), the sole holder of the upgrade role on both proxies.
**Likelihood:** Config already wrong on `main`; harmful when the migration batch or the new AccessManager grants are derived from it.
**Proof:** §6 (`getMinDelay()` reverts on `0x7731…`, returns 86400 on `0xD823…`; role members).
**Recommendation:** Set `timelock` to `0xD8236031…`, add `v1AccessControl: 0x7731…`, and grant the new AccessManager ADMIN to the timelock in the same batch as the upgrade.
**Invariant broken:** none.

### [LOW] U-7 — Upgrade order dependency: stcUSD upgraded before cUSD reverts on every valuation call; v1 `Pausable` state is dropped
**Location:** `contracts/cap/Wrapper.sol:L50-L52`; v1 `Vault` `whenNotPaused` on mint/burn/redeem/borrow/repay.
**Impact:** Wrong ordering leaves stcUSD unusable until cUSD follows (timelock delay ⇒ a day of a dead stcUSD if batched separately); a v1 pause used to freeze the system during migration silently ends at the upgrade because HEAD ignores `openzeppelin.storage.Pausable`.
**Proof:** `test_TABLE_4_stcusdBehaviour` ("stcUSD upgraded BEFORE cUSD": `totalAssets/convertToAssets/maxWithdraw -> REVERTS`); live `paused()==false` today.
**Recommendation:** One timelock batch: cUSD upgrade+migrate, then stcUSD upgrade+migrate; do not rely on the v1 pause bit surviving.
**Invariant broken:** none.

### Informational
- U-8 The stored ERC20 name stays "cap USD" (fresh deploys say "Cap USD", `DeployInfra.sol:L100`); harmless, but off-chain lists keyed on name will differ.
- U-9 `Wrapper` DeadShares seeding (`_deposit` mints `DeadShares.SHARES` when `totalSupply()==0`) never triggers on the live proxy (supply 74.7 M) — correct.
- U-10 The ERC-7540 queue and operator namespaces start empty, which is fine; but `requestRedeem` being live while claims are dead (U-1) means users can *lose custody* during the broken window — ordering the reinitializer atomically removes the window.
- U-11 v1 `CapToken` had `insuranceFund`, `feeAuction`/`interestReceiver`, whitelist/depositCap/fee data — all abandoned; no HEAD equivalent (informational, by design).

## 9. Invariants
- **Broken:** I26 (`redeem(maxRedeem(a))` reverts because `maxRedeem` reverts), I34 (`cUSD.balanceOf(stablecoin) ≥ redemptionQueue()+remaining()` un-evaluable with `asset()==0`; with a reinitializer it holds only because the queue is empty — reported backing is 26,000× the reserve on hand), I35 holds trivially (0+0 ≤ S).
- **New invariants the upgrade path implies (not in the plan):**
  - N-U1: for every UUPS proxy, `authority() != address(0)` and `IAccessManager(authority()).canCall(timelock, proxy, upgradeToAndCall.selector)` must hold immediately after any upgrade transaction (else the proxy is bricked).
  - N-U2: after migration, `Initializable._initialized == 2` on both proxies, `asset()==USDC`, `underlyingDecimals()==6`, `optedIn(stcUSD)==true`, `stakedSupply() ≥ balanceOf(stcUSD)`.
  - N-U3: at migration, `USDC.balanceOf(cUSD)·10^12 + creditBackedSupply + badDebt ≥ totalSupply()` — otherwise `unlockedSupply()` under-delivers while `totalAssets()` over-reports.

## 10. Hypotheses
- **P22 — CONFIRMED.** `Initializable` is at version 1 on both proxies (on chain); `initialize` reverts; `underlyingDecimals/irm/reserveVault/authority/stablecoin` all zero; v1 namespaces (`ERC4626` for cUSD, `AccessManaged` for both) were never written; live reserve is not on hand (3,219 of 84.88 M USDC) ⇒ `unlockedSupply()` reverts on a bare upgrade and equals 3,219 cUSD after a reinitializer; `Wrapper.initialize`'s `optIn` never runs and nothing else can run it; migration order documented in §4. Two Critical (U-1, U-2), two High (U-3, U-4), three Low.

## Appendix: gas & style
- `StablecoinV2` copy shows `layout at` contracts cannot be inherited (solc error 8894) — any migration/extension has to live in `Stablecoin.sol` itself; worth a comment near `layout at`.
- `Wrapper.initialize` derives name/symbol from the asset ("Staked Cap USD"/"stcUSD") but the live token is "Staked cap USD"; a reinitializer should not touch ERC20 metadata.
- `test/unit/cap/Stablecoin.t.sol:L784-L795` tests `upgradeToAndCall` only on a freshly initialised proxy of the *same* code; a fork test against `0xcCcc…`/`0x8888…` (this file's `U_LiveUpgrade.t.sol`) would have caught every finding here.
