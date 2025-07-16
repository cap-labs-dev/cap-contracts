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
| 15 | property_cap_token_backed_1_to_1 | cUSD (capToken) must be backed 1:1 by stable underlying assets | |
| 16 | doomsday_debt_token_solvency | DebtToken balance ≥ total vault debt at all times | |
| 17 | property_total_borrowed_less_than_total_supply | Total cUSD borrowed < total supply (utilization < 1e27) | |
| 18 | property_staked_cap_value_non_decreasing | Staked cap token value must increase or stay the same over time | |
| 19 | property_utilization_ratio_never_greater_than_1e27 | Utilization ratio is never greater than 1e27 | |
| 20 | property_maxWithdraw_less_than_loaned_and_reserve | sum of all `maxWithdraw` for users should be <= loaned + reserve | |
| 21 | capToken_burn | User always receives at least the minimum amount out | |
| 22 | capToken_burn | User always receives at most the expected amount out | |
| 23 | capToken_burn | Total cap supply decreases by no more than the amount out | |
| 24 | capToken_burn | Fees are always nonzero when burning | |
| 25 | capToken_burn | Fees are always <= the amount out | |
| 26 | capToken_burn | Burning reduces cUSD supply, must always round down | |
| 27 | capToken_burn | Burners must not receive more asset value than cUSD burned | |
| 28 | capToken_burn | User can always burn cap token if they have sufficient balance of cap token | |
| 29 | capToken_divestAll | ERC4626 must always be divestable | |
| 30 | capToken_mint | User always receives at least the minimum amount out | |
| 31 | capToken_mint | User always receives at most the expected amount out | |
| 32 | capToken_mint | Fees are always nonzero when minting | |
| 33 | capToken_mint | Fees are always <= the amount out | |
| 34 | capToken_mint | Minting increases vault assets based on oracle value | |
| 35 | capToken_mint | User can always mint cap token if they have sufficient balance of depositing asset | |
| 36 | capToken_mint | Asset cannot be minted when it is paused | |
| 37 | capToken_redeem | User always receives at least the minimum amount out | |
| 38 | capToken_redeem | User always receives at most the expected amount out | |
| 39 | capToken_redeem | Total cap supply decreases by no more than the amount out | |
| 40 | capToken_redeem | Fees are always <= the amount out | |
| 41 | capToken_redeem | User can always redeem cap token if they have sufficient balance of cap token | |
| 42 | doomsday_liquidate | Liquidate should always succeed for liquidatable agent | |
| 43 | doomsday_liquidate | Liquidating a healthy agent should not generate bad debt | |
| 44 | doomsday_repay | Repay should always succeed for agent that has debt | |
| 45 | lender_borrow | Asset cannot be borrowed when it is paused | |
| 46 | lender_borrow | Borrower should be healthy after borrowing (self-liquidation) | |
| 47 | lender_borrow | Borrower asset balance should increase after borrowing | |
| 48 | lender_borrow | Borrower debt should increase after borrowing | |
| 49 | lender_borrow | Total borrows should increase after borrowing | |
| 50 | lender_borrow | Borrow should never revert with arithmetic error | |
| 51 | lender_initiateLiquidation | agent should not be liquidatable with health > 1e27 | |
| 52 | lender_initiateLiquidation | Agent should always be liquidatable if it is unhealthy | |
| 53 | lender_liquidate | Liquidate should never revert with arithmetic error | |
| 54 | lender_liquidate | Liquidation should be profitable for the liquidator | |
| 55 | lender_liquidate | Agent should not be liquidatable with health > 1e27 | |
| 56 | lender_liquidate | Liquidations should always improve the health factor | |
| 57 | lender_liquidate | Emergency liquidations should always be available when emergency health is below 1e27 | |
| 58 | lender_liquidate | Partial liquidations should not bring health above 1.25 | |
| 59 | lender_liquidate | Agent should have their totalDelegation reduced by the liquidated value | |
| 60 | lender_liquidate | Agent should have their totalSlashableCollateral reduced by the liquidated value | |
| 61 | lender_realizeInterest | agent's total debt should not change when interest is realized | |
| 62 | lender_realizeInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized | |
| 63 | lender_realizeInterest | vault debt and total borrows should increase by the same amount after a call to `realizeInterest` | |
| 64 | lender_realizeInterest | health should not change when `realizeInterest` is called | |
| 65 | lender_realizeInterest | interest can only be realized if there are sufficient vault assets | |
| 66 | lender_realizeInterest | realizeInterest should only revert with `ZeroRealization()` if paused or `totalUnrealizedInterest == 0`, otherwise should always update the realization value | |
| 67 | lender_realizeRestakerInterest | vault debt should increase by the same amount that the underlying asset in the vault decreases when restaker interest is realized | |
| 68 | lender_realizeRestakerInterest | vault debt and total borrows should increase by the same amount after a call to `realizeRestakerInterest` | |
| 69 | lender_realizeRestakerInterest | health should not change when `realizeRestakerInterest` is called | |
| 70 | lender_realizeRestakerInterest | restakerinterest can only be realized if there are sufficient vault assets | |
| 71 | lender_repay | repay should never revert with arithmetic error | |
| 72 | property_fractional_reserve_vault_has_reserve_amount_of_underlying_asset | fractional reserve vault must always have reserve amount of underyling asset | |
| 73 | property_liquidation_does_not_increase_bonus | liquidation does not increase bonus | |
| 74 | property_borrower_cannot_borrow_more_than_ltv | borrower can't borrow more than LTV | |
| 75 | property_health_should_not_change_when_realizeRestakerInterest_is_called | health should not change when realizeRestakerInterest is called | |
| 76 | property_no_operation_makes_user_liquidatable | no operation should make a user liquidatable | |
| 77 | property_dust_on_repay | after all users have repaid their debt, their balance of `debtToken` should be 0 | |
| 78 | property_zero_debt_is_borrowing | if the debt token balance is 0, the agent should not be isBorrowing | |
| 79 | property_agent_always_has_more_than_min_borrow | agent always has more than minBorrow balance of debtToken | |
| 80 | property_lender_does_not_accumulate_dust | lender does not accumulate dust | |
| 81 | property_debt_zero_after_repay | after all users have repaid their debt, the `reserve.debt` should be 0 | |
| 82 | doomsday_repay_all | repaying all debt for all actors transfers same amount of interest as would have been transferred by `realizeInterest` | |
| 83 | doomsday_manipulate_utilization_rate | borrowing and repaying an amount in the same block shouldn't change the utilization rate | |
| 84 | property_previewRedeem_greater_than_loaned | `previewRedeem(totalSupply)` >= `loaned` | |
| 85 | capToken_divestAll | no assets should be left in the vault after divesting all | |
| 86 | property_available_balance_never_reverts | available balance should never revert | |
| 87 | property_maxBorrow_never_reverts | maxBorrowable should never revert | |
| 88 | property_no_agent_borrowing_total_debt_should_be_zero | if no agent is borrowing, the total debt should be 0 | |
| 89 | property_no_agent_borrowing_utilization_rate_should_be_zero | if no agent is borrowing, the utilization rate should be 0 | |
| 90 | doomsday_maxBorrow | maxBorrowable after borrowing max should be 0 | |
| 91 | doomsday_maxBorrow | if no agent is borrowing, the current utilization index should be 0 | |
| 92 | doomsday_compound_vs_linear_accumulation | interest accumulation should be the same whether it's realized or not | |
| 93 | property_debt_token_total_supply_greater_than_vault_debt | debtToken.totalSupply should never be less than reserve.debt | |
| 94 | property_healthy_account_stays_healthy_after_liquidation | A healthy account (collateral/debt > 1) should never become unhealthy after a liquidation | |
| 95 | property_no_bad_debt_creation_on_liquidation | A liquidatable account that doesn't have bad debt should not suddenly have bad debt after liquidation | |
| 96 | lender_cancelLiquidation | cancelLiquidation should always succeed when health is above 1e27 | |
| 97 | lender_cancelLiquidation | cancelLiquidation should revert when health is below 1e27 | |
| 98 | property_maxLiquidatable_never_reverts | maxLiquidatable should never revert due to arithmetic error | |
| 99 | property_bonus_never_reverts | bonus should never revert due to arithmetic error | |
| 100 | property_staked_cap_total_assets_never_reverts | staked cap total assets should never revert due to arithmetic error | |
| 101 | property_debt_token_utilization_only_increases | debt token utilization only increases | |
| 102 | property_storedTotal_only_increases_after_lockDuration | storedTotal only increases after lockDuration | |
| 103 | property_lockedProfit_decreases_over_lockDuration | lockedProfit decreases over time within lockDuration | |