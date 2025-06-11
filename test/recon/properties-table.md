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
| 9  | capToken_mint | Asset cannot be minted when it is paused | |
| 10 | capToken_mint | Fees are always <= the amount out | |
| 11 | capToken_redeem | User can always redeem cap token if they have sufficient balance of cap token | |
| 12 | capToken_redeem | User always receives at least the minimum amount out | |
| 13 | capToken_redeem | User always receives at most the expected amount out | |
| 14 | capToken_redeem | Total cap supply decreases by no more than the amount out | |
| 15 | capToken_redeem | Fees are always <= the amount out | |
| 16 | capToken_burn | User can always burn cap token if they have sufficient balance of cap token | |
| 17 | capToken_burn | User always receives at least the minimum amount out | |
| 18 | capToken_burn | User always receives at most the expected amount out | |
| 19 | capToken_burn | Total cap supply decreases by no more than the amount out | |
| 20 | capToken_burn | Fees are always nonzero when burning | |
| 21 | capToken_burn | Fees are always <= the amount out | |
| 22 | property_utilization_index_only_increases | Utilization index only increases | |
| 23 | property_utilization_ratio | Utilization ratio only increases after a borrow or realizing interest | |
| 24 | property_vault_balance_does_not_change_redeemAmountsOut | If the vault invests/divests it shouldn't change the redeem amounts out | |
| 25 | property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token | Agent can never have less than minBorrow balance of debt token | |
| 26 | property_repaid_debt_equals_zero_debt | If all users have repaid their debt (have 0 DebtToken balance), reserve.debt == 0 | |
| 27 | lender_repay | Repay should never revert due to under/overflow | |
| 28 | lender_realizeInterest | agent's total debt should not change when interest is realized | |
| 29 | lender_realizeInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized | |
| 30 | lender_realizeInterest | vault debt and total borrows should increase by the same amount after a call to `realizeInterest` | |
| 31 | lender_borrow | Asset cannot be borrowed when it is paused | |
| 32 | lender_borrow | Borrower should be healthy after borrowing (self-liquidation) | |
| 33 | lender_borrow | Borrower asset balance should increase after borrowing | |
| 34 | lender_borrow | Borrower debt should increase after borrowing | |
| 35 | lender_borrow | Total borrows should increase after borrowing | |
| 36 | property_borrowed_asset_value | loaned assets value < delegations value (strictly) or the position is liquidatable | |
| 37 | property_health_not_changed_with_realizeInterest | health should not change when interest is realized | |
| 38 | lender_realizeInterest | realizeInterest should only revert with `ZeroRealization()` if paused or `totalUnrealizedInterest == 0`, otherwise should always update the realization value | |
| 39 | lender_realizeInterest, lender_realizeRestakerInterest | agent's total debt should not change when interest is realized | |
| 40 | lender_realizeInterest, lender_realizeRestakerInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when restaker interest is realized | |
| 41 | lender_realizeInterest, lender_realizeRestakerInterest | vault debt and total borrows should increase by the same amount after a call to `realizeRestakerInterest` | |
| 42 | lender_initiateLiquidation | agent should not be liquidatable with health > 1e27 | |
| 43 | lender_initiateLiquidation | Agent should always be liquidatable if it is unhealthy | |
| 44 | lender_liquidate | liquidation should be profitable for the liquidator | |
| 45 | lender_liquidate | agent should not be liquidatable with health > 1e27 | |
| 46 | lender_liquidate | Liquidations should always improve the health factor | |
| 47 | lender_liquidate | Emergency liquidations should always be available when emergency health is below 1e27 | |
| 48 | lender_liquidate | Partial liquidations should not bring health above 1.25 | |
| 49 | doomsday_liquidate | Liquidate should always succeed for liquidatable agent | |
| 50 | doomsday_repay | Repay should always succeed for agent that has debt | |
| 51 | property_total_system_collateralization | System must be overcollateralized after all liquidations | |
| 52 | property_delegated_value_greater_than_borrowed_value | Delegated value must be greater than borrowed value, if not the agent should be liquidatable | |
| 53 | property_ltv | LTV is always <= 1e27 | |
