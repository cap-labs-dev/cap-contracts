# Killing tests for the round-3 mutation run (Workstream F)

Every test in this directory passes on `cap-network` @ `a843c1d` and fails on at least one
mutant that the stock `test/` suite (574 tests) lets through. The write-up is
`audit/v3/test-suite-assessment.md` §2; `mutation.log` in this directory is the machine-readable
record, one line per mutant (`id,file,line,orig,mutant,result_before,result_after,seconds`).

## Run the killing tests on HEAD

```sh
FOUNDRY_TEST=audit/v3/tests/mutants forge test --match-path 'audit/v3/tests/mutants/*' -vv
```

`FOUNDRY_TEST` is required: `foundry.toml` points `test = "test"`, and pointing it at the whole
`audit/v3/tests` tree compiles every other workstream's scratch files.

## Reproduce a mutant

Gambit v1.0.6 (binary in the audit scratchpad, `tools/gambit`), solc 0.8.36:

```sh
gambit mutate --filename contracts/cap/market/FixedMarket.sol --outdir /tmp/gambit/FixedMarket \
  --solc /Users/weso/.svm/0.8.36/solc-0.8.36 \
  --solc_remappings "@openzeppelin/=node_modules/@openzeppelin/" --solc_allow_paths .
```

`/tmp/gambit/FixedMarket/mutants.log` lists `id,operator,file,line:col,original,mutant`; the
mutated source is `/tmp/gambit/FixedMarket/mutants/<id>/contracts/cap/market/FixedMarket.sol`.
Ids in `mutation.log` are `<Contract>#<id>` in that numbering (Gambit is deterministic for a
given source and solc). Hand-authored mutants `H01`–`H28` are exact string replacements listed
in the scratchpad's `hand_mutants.py`; the `orig` and `mutant` columns of `mutation.log` carry
the replacement.

To replay one mutant (never in the main checkout — use a `git worktree`):

```sh
git worktree add /tmp/wt a843c1d && cd /tmp/wt
cp -r /Users/weso/cap-contracts/audit /tmp/wt/            # the killing tests
cp /tmp/gambit/FixedMarket/mutants/122/contracts/cap/market/FixedMarket.sol contracts/cap/market/FixedMarket.sol
forge test -q                                              # result_before: the stock suite
FOUNDRY_TEST=audit/v3/tests/mutants forge test -q          # result_after: the killing tests
git checkout -- contracts/ && git status --porcelain contracts/ test/   # must be empty
```

A mutant is `KILLED` when `forge test` exits non-zero, `SURVIVED` when it exits zero, `INVALID`
when the compiler rejects it (none did in this run).

## Files

| file | kills |
|---|---|
| `FixedPartial.t.sol` | FixedMarket#129, #161, #138; H19, H25 |
| `FixedWriteOff.t.sol` | FixedMarket#122 |
| `FloatingAccrual.t.sol` | FloatingMarket#17, #29; H23 |
| `Implementations.t.sol` | `<Contract>#1` (`_disableInitializers`) for Tranche, Underwriter, Stablecoin, InterestRateModel, Registry, Oracle#7 |
| `LockedValuePartial.t.sol` | BaseMarket#161, #162; H01, H02, H11 |
| `MarketConfig.t.sol` | BaseMarket#10, Registry#25, Registry#79, Registry#211; H16, H24 |
| `RedeemFifo.t.sol` | ERC7540AsyncRedeem#50, #51, #58, #120, #121, #176, #219, #254, #260, #261, #274, #288 |
| `StablecoinGuards.t.sol` | Stablecoin#64, #86, #107; H10, H21 (and evidence that #303 is unreachable) |
| `UnderwriterQueue.t.sol` | Underwriter#17, #33, #34, #37, #38, #53, #54, #57, #58, #61 |
| `VestingOptOut.t.sol` | PremiumVesting#55 |
