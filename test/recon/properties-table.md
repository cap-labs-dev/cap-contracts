| #  | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1  | property_sum_of_deposits | Sum of deposits is less than or equal to total supply | |
| 2  | property_sum_of_withdrawals | Sum of deposits + sum of withdrawals is less than or equal to total supply | |
| 3  | property_vault_solvency_assets | totalSupplies for a given asset is always <= vault balance + totalBorrows + fractionalReserveBalance | |
| 4  | property_vault_solvency_borrows | totalSupplies for a given asset is always >= totalBorrows | |
| 5  | property_utilization_index_only_increases | Utilization index only increases | |
| 6  | property_utilization_ratio | Utilization ratio only increases after a borrow or realizing interest | |
| 7  | property_vault_balance_does_not_change_redeemAmountsOut | If the vault invests/divests it shouldn't change the redeem amounts out | |
| 8  | property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token | Agent can never have less than minBorrow balance of debt token | |
| 9  | property_repaid_debt_equals_zero_debt | If all users have repaid their debt (have 0 DebtToken balance), reserve.debt == 0 | |
| 10 | property_borrowed_asset_value | loaned assets value < delegations value (strictly) or the position is liquidatable | |
| 11 | property_health_not_changed_with_realizeInterest | health should not change when interest is realized | |
| 12 | property_total_system_collateralization | System must be overcollateralized after all liquidations | |
| 13 | property_delegated_value_greater_than_borrowed_value | Delegated value must be greater than borrowed value, if not the agent should be liquidatable | |
| 14 | property_ltv | LTV is always <= 1e27 | |
| 15 | capToken_burn | User can always burn cap token if they have sufficient balance of cap token | |
| 16 | capToken_burn | User always receives at least the minimum amount out | |
| 17 | capToken_burn | User always receives at most the expected amount out | |
| 18 | capToken_burn | Total cap supply decreases by no more than the amount out | |
| 19 | capToken_burn | Fees are always nonzero when burning | |
| 20 | capToken_burn | Fees are always <= the amount out | |
| 21 | capToken_divestAll | ERC4626 must always be divestable | |
| 22 | capToken_mint | User can always mint cap token if they have sufficient balance of depositing asset | |
| 23 | capToken_mint | User always receives at least the minimum amount out | |
| 24 | capToken_mint | User always receives at most the expected amount out | |
| 25 | capToken_mint | Fees are always nonzero when minting | |
| 26 | capToken_mint | Asset cannot be minted when it is paused | |
| 27 | capToken_mint | Fees are always <= the amount out | |
| 28 | capToken_redeem | User can always redeem cap token if they have sufficient balance of cap token | |
| 29 | capToken_redeem | User always receives at least the minimum amount out | |
| 30 | capToken_redeem | User always receives at most the expected amount out | |
| 31 | capToken_redeem | Total cap supply decreases by no more than the amount out | |
| 32 | capToken_redeem | Fees are always <= the amount out | |
| 33 | doomsday_liquidate | Liquidate should always succeed for liquidatable agent | |
| 34 | doomsday_repay | Repay should always succeed for agent that has debt | |
| 35 | lender_borrow | Asset cannot be borrowed when it is paused | |
| 36 | lender_borrow | Borrower should be healthy after borrowing (self-liquidation) | |
| 37 | lender_borrow | Borrower asset balance should increase after borrowing | |
| 38 | lender_borrow | Borrower debt should increase after borrowing | |
| 39 | lender_borrow | Total borrows should increase after borrowing | |
| 40 | lender_initiateLiquidation | agent should not be liquidatable with health > 1e27 | |
| 41 | lender_initiateLiquidation | Agent should always be liquidatable if it is unhealthy | |
| 42 | lender_liquidate | liquidation should be profitable for the liquidator | |
| 43 | lender_liquidate | agent should not be liquidatable with health > 1e27 | |
| 44 | lender_liquidate | Liquidations should always improve the health factor | |
| 45 | lender_liquidate | Emergency liquidations should always be available when emergency health is below 1e27 | |
| 46 | lender_liquidate | Partial liquidations should not bring health above 1.25 | |
| 47 | lender_realizeInterest | agent's total debt should not change when interest is realized | |
| 48 | lender_realizeInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized | |
| 49 | lender_realizeInterest | vault debt and total borrows should increase by the same amount after a call to `realizeInterest` | |
| 50 | lender_realizeInterest | health should not change when `realizeInterest` is called | |
| 51 | lender_realizeInterest | realizeInterest should only revert with `ZeroRealization()` if paused or `totalUnrealizedInterest == 0`, otherwise should always update the realization value | |
| 52 | lender_realizeRestakerInterest | agent's total debt should not change when interest is realized | |
| 53 | lender_realizeRestakerInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when restaker interest is realized | |
| 54 | lender_realizeRestakerInterest | vault debt and total borrows should increase by the same amount after a call to `realizeRestakerInterest` | |
| 55 | lender_realizeRestakerInterest | health should not change when `realizeRestakerInterest` is called | |
| 56 | property_cap_token_backed_1_to_1 | cUSD (capToken) must be backed 1:1 by stable underlying assets | |
| 57 | property_debt_token_balance_gte_total_vault_debt | DebtToken balance ≥ total vault debt at all times | |
| 58 | property_total_borrowed_less_than_total_supply | Total cUSD borrowed < total supply (utilization < 1e27) | |
| 59 | property_staked_cap_value_non_decreasing | Staked cap token value must increase or stay the same over time | |
| 60 | capToken_burn | Burning reduces cUSD supply, must always round down | |
| 61 | capToken_burn | Burners must not receive more asset value than cUSD burned | |
| 62 | capToken_mint | Minting increases vault assets based on oracle value | |