| #  | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1  | property_sum_of_deposits | Sum of deposits is less than or equal to total supply | |
| 2  | property_sum_of_withdrawals | Sum of deposits + sum of withdrawals is less than or equal to total supply | |
| 3  | property_vault_solvency_assets | totalSupplies for a given asset is always <= vault balance + totalBorrows + fractionalReserveBalance | |
| 4  | property_vault_solvency_borrows | totalSupplies for a given asset is always >= totalBorrows | |
| 5  | capToken_mint | User can always mint cap token if they have sufficient balance of depositing asset | |
| 6  | capToken_mint | User always receives at least the minimum amount out | |
| 7  | capToken_mint | User always receives at most the expected amount out | |
| 8  | capToken_mint | Fees are always nonzero when minting | |
| 9  | capToken_mint | Fees are always <= the amount out | |
| 10 | capToken_redeem | User can always redeem cap token if they have sufficient balance of cap token | |
| 11 | capToken_redeem | User always receives at least the minimum amount out | |
| 12 | capToken_redeem | User always receives at most the expected amount out | |
| 13 | capToken_redeem | Total cap supply decreases by no more than the amount out | |
| 14 | capToken_redeem | Fees are always <= the amount out | |
| 15 | capToken_burn | User can always burn cap token if they have sufficient balance of cap token | |
| 16 | capToken_burn | User always receives at least the minimum amount out | |
| 17 | capToken_burn | User always receives at most the expected amount out | |
| 18 | capToken_burn | Total cap supply decreases by no more than the amount out | |
| 19 | capToken_burn | Fees are always nonzero when burning | |
| 20 | capToken_burn | Fees are always <= the amount out | |
| 21 | property_utilization_index_only_increases | Utilization index only increases | |
| 22 | property_utilization_ratio | Utilization ratio only increases after a borrow or realizing interest | |
| 23 | property_vault_balance_does_not_change_redeemAmountsOut | If the vault invests/divests it shouldn't change the redeem amounts out | |
| 24 | property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token | Agent can never have less than minBorrow balance of debt token | |
| 25 | property_repaid_debt_equals_zero_debt | If all users have repaid their debt (have 0 DebtToken balance), reserve.debt == 0 | |
| 26 | lender_repay | Repay should never revert due to under/overflow | |
| 27 | lender_realizeInterest | agent's total debt should not change when interest is realized | |
| 28 | lender_realizeInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized | |
| 29 | lender_realizeInterest | vault debt and total borrows should increase by the same amount after a call to `realizeInterest` | |
| 30 | lender_borrow | Asset cannot be borrowed when it is paused | |
| 31 | lender_borrow | Borrower should be healthy after borrowing (self-liquidation) | |
| 32 | lender_borrow | Borrower asset balance should increase after borrowing | |
| 33 | lender_borrow | Borrower debt should increase after borrowing | |
| 34 | lender_borrow | Total borrows should increase after borrowing | |
| 35 | property_borrowed_asset_value | loaned assets value < delegations value (strictly) or the position is liquidatable | |
| 36 | property_health_not_changed_with_realizeInterest | health should not change when interest is realized | |
| 37 | lender_realizeInterest | realizeInterest should only revert with `ZeroRealization()` if paused or `totalUnrealizedInterest == 0`, otherwise should always update the realization value | |
| 38 | lender_realizeInterest, lender_realizeRestakerInterest | agent's total debt should not change when interest is realized | |
| 39 | lender_realizeInterest, lender_realizeRestakerInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when restaker interest is realized | |
| 40 | lender_realizeInterest, lender_realizeRestakerInterest | vault debt and total borrows should increase by the same amount after a call to `realizeRestakerInterest` | |
| 41 | lender_initiateLiquidation | agent should not be liquidatable with health > 1e27 | |
| 42 | lender_initiateLiquidation | Agent should always be liquidatable if it is unhealthy | |
| 43 | lender_liquidate | agent should not be liquidatable with health > 1e27 | |
| 44 | lender_liquidate | Liquidations should always improve the health factor | |
| 45 | lender_liquidate | Emergency liquidations should always be available when emergency health is below 1e27 | |
| 46 | doomsday_liquidate | Liquidate should always succeed for liquidatable agent | |
| 47 | doomsday_repay | Repay should always succeed for agent that has debt | |
| 48 | capToken_divestAll | ERC4626 must always be divestable | |