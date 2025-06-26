# Recon invariant testing suite

## Introduction
The Recon team was engaged by the Cap team to implement an invariant testing suite over the course of 4 weeks. The resulting test suite tests 80+ properties which are outlined in the [properties-table](https://github.com/Recon-Fuzz/cap-contracts/blob/feat/recon/test/recon/properties-table.md) file.

## Usage
This test suite uses the [Chimera Framework](https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html) to allow testing using multiple fuzzers and formal verification tools. 

### Property Testing
This test suite uses assertion property tests defined for the system contracts in the [`Properties`](https://github.com/Recon-Fuzz/cap-contracts/blob/feat/recon/test/recon/Properties.sol) contract and in the function handlers in the [targets/ directory](https://github.com/Recon-Fuzz/cap-contracts/tree/feat/recon/test/recon/targets).  

See [this section](https://book.getrecon.xyz/extra/advanced.html) of the Recon book about techniques we use when writing properties and how we ensure full coverage.

#### Echidna Property Testing
To locally test properties using Echidna, run the following command in your terminal:
```shell
echidna . --contract CryticTester --config echidna.yaml
```

### Foundry Testing
Broken properties found when running Echidna can be turned into unit tests for easier debugging with [Recon's tools](https://getrecon.xyz/tools/echidna) and added to the `CryticToFoundry` contract.

```shell
forge test --match-contract CryticToFoundry -vv
```

## Expanding Target Functions
See [this section](https://book.getrecon.xyz/writing_invariant_tests/sample_project.html#building-target-functions) of the Recon book on how to add additional target functions for testing. 

## Uploading Fuzz Job To Recon

You can offload your fuzzing job to Recon to run long duration jobs and share test results with collaborators using the [jobs page](https://getrecon.xyz/dashboard/jobs)

See the [Recon book](https://book.getrecon.xyz/using_recon/running_jobs.html) for more info on how to upload a job to the Recon web app. 

## Improvements to be made
Over the course of the engagement, a best effort attempt was made to define as many properties as possible which would test the most important logic of the system. However, given the time-constrained nature of the engagement there were some parts that we believe require more attention which we have outlined below.  

### Room for improvement
- Checks for agent health need to be made after all operations. This already led to the discovery of [issue 22](https://github.com/Recon-Fuzz/cap-invariants/issues/22) but the property should be refactored to exclude this case and check for others.
- [Issue 25](https://github.com/Recon-Fuzz/cap-invariants/issues/25) highlights that their system doesn't fully support 18 decimal tokens so could further check compatibility throughout other operations.

### Not fully debugged
- [Issue 27](https://github.com/Recon-Fuzz/cap-invariants/issues/27) shows that a liquidation can fail for a valid call of 1 wei but we need to try and escalate this to see if it fails for values greater than 1 wei.
- [Issue 28](https://github.com/Recon-Fuzz/cap-invariants/issues/28) shows that the utilization rate can be manipulated in the same way that Liam had previously identified by borrowing and repaying in the same block. Still need to understand the root cause. 

### Further considerations
- possible side effects of debtToken insolvency in [issue 20](https://github.com/Recon-Fuzz/cap-invariants/issues/20)
- [Issue 23](https://github.com/Recon-Fuzz/cap-invariants/issues/23) shows that a borrower's LTV can increase past the expected amount if restaker interest is realized so need a determination from the team whether LTV should only be limited immediately after a borrow operation or after realizing interest as well. Would also need to investigate possible side effects of LTV being greater than the max allowable on the rest of the system.
- ways to manipulate the utilization rate unfairly 
- [Issue 29](https://github.com/Recon-Fuzz/cap-invariants/issues/29) shows that interest realized via `repay` and `realizeInterest` is different, this could have consequences for borrowers unfairly paying more interest than is due
- entire interest realization flow and possibility to game it so that it forces other users to pay more interest, avoid paying same interest as others, potential to force insolvency via interest realization
- `StakedCap` and `DebtToken` could use further analysis and properties defined for them
- edge cases related to the fee rate capping mechanism, fees initially start with a flat rate of 0.5% then it becomes dynamic (Low | Optimal | High) using slope0 and slope1
- MathUtils calculations and how compound interest can affect overall system health