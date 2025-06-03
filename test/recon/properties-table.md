| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | property_sum_of_deposits | Sum of deposits is less than or equal to total supply | |
| 2 | property_sum_of_withdrawals | Sum of withdrawals is less than or equal to total supply | |
| 3 | property_vault_solvency_assets | totalSupplies for a given asset is always <= vault balance | |
| 4 | property_vault_solvency_borrows | totalSupplies for a given asset is always >= totalBorrows | |
| 5 | capToken_mint | User can always mint cap token if they have sufficient balance of depositing asset | |
| 6 | capToken_mint | User always receives at least the minimum amount out | |
| 7 | capToken_mint | User always receives at most the expected amount out | |
| 8 | capToken_mint | Fees are always nonzero when minting | |
| 9 | capToken_redeem | User can always redeem cap token if they have sufficient balance of cap token | |
| 10 | capToken_redeem | User always receives at least the minimum amount out | |
| 11 | capToken_redeem | User always receives at most the expected amount out | |
| 12 | capToken_redeem | Total cap supply decreases by no more than the amount out | |
| 13 | capToken_burn | User can always burn cap token if they have sufficient balance of cap token | |
| 14 | capToken_burn | User always receives at least the minimum amount out | |
| 15 | capToken_burn | User always receives at most the expected amount out | |
| 16 | capToken_burn | Total cap supply decreases by no more than the amount out | |
| 17 | capToken_burn | Fees are always nonzero when burning | |
