# Known issues and accepted behavior

Based on commit `b0a6f64a18bdb6ab97066e0eb086ae6c545ea9d8`, reviewed on 23 September 2026. Deployed settings may differ. “Accepted” describes the protocol's decision, not a claim that the behavior is harmless.

## Accepted risks

### cUSD reserves and bad debt

#### Discounted repayment and redemption of borrowed cUSD

- **Issue:** Borrowers can buy discounted cUSD to repay debt at par, or redeem borrowed cUSD against available reserves without repaying the loan.
- **Accepted:** cUSD remains fungible regardless of how it was minted. No repayment haircut or reserve allocation by holder is enforced.
- **Fixed:** Shortfall pricing excludes performing credit, so credit issuance and repayment alone no longer change another holder's identical redemption quote. Cash can still be exhausted through redemptions.

#### Holders can exit before a loss is recognized

- **Issue:** Reserve or credit losses may be observable before recognition changes redemption pricing. Earlier exits can leave more loss with remaining holders.
- **Accepted:** Holders can exit between loss visibility and guardian action, limited to reserves on hand at redemption and the applicable withdrawal limits.
- **Mitigation:** Prompt monitoring and private submission reduce some timing risk but cannot eliminate it. Credit-loss recognition must also respect liquidation ordering.

#### Reserve recovery needs explicit bad-debt coverage

- **Issue:** `invest` and `recall` do not mark investment gains or losses. Recovered reserves do not automatically reduce recognized bad debt.
- **Accepted:** Recovery accounting remains an operational responsibility.
- **Procedure:** The account holding the recovered reserve tokens deposits them into Stablecoin to mint cUSD, then calls `coverBadDebt` to burn that cUSD and reduce the recorded bad debt. Reconcile against remaining bad debt and avoid counting a direct recall as a separate new deposit.

#### Shortfall calculations can overflow at extreme supply

- **Issue:** Checked products such as `supply * recognized` can overflow during shortfall conversions.
- **Accepted:** No change is planned at this scale: approximately `2^128` share units, or `3.4e20` cUSD, when the factors are similarly sized. The exact boundary depends on state and execution path.

### Fixed borrowing and repayment

#### Fixed rates omit unminted floating premiums

- **Issue:** Floating debt accrues before matching premium enters credit-backed supply. A fixed borrower can receive a lower quote before that premium is realized.
- **Accepted:** Fixed quoting does not checkpoint all floating markets. Later realization does not reprice the fixed loan.
- **Mitigation:** Regular keeper realization reduces the gap but provides no atomic guarantee. Long inactivity and high rates increase exposure.

#### Averaged utilization can misprice fixed loans

- **Issue:** Reserve movements and temporary deposits can leave averaged utilization above or below live utilization, affecting premiums for the full quoted term.
- **Accepted:** Pricing retains its averaging lag. Temporary liquidity can influence a quote and exit if reserves remain available; influencing the average does not require waiting a full averaging period.
- **Rationale:** Pricing from spot utilization alone would let brief deposits or withdrawals manipulate the rate locked in for an entire fixed loan. Averaging reduces sensitivity to these short-lived liquidity changes, at the cost of responding more slowly to lasting changes.
- **Mitigation:** Fixed borrowers can cap the combined premium on `borrow` and `borrowMore` with `maxPremium`. Execution reverts above the cap. This bounds the accepted cost without removing averaging lag; loan extensions remain uncapped.

#### Splitting fixed borrows can reduce premiums

- **Issue:** Splitting a fixed borrow into smaller draws can cost less total premium than borrowing the same principal for the same term in one draw.
- **Accepted:** Each draw is priced separately; the contracts do not aggregate draws to enforce the single-borrow price.
- **Mitigation:** Borrowers are permissioned and expected not to split draws solely to reduce premiums. This conduct restriction is not enforced on-chain.

#### Early fixed repayment does not refund premium

- **Issue:** Repaying a fixed loan early does not reduce the premium charged for its full term.
- **Accepted:** The full premium becomes debt when charged. Early repayment does not cancel its unearned portion or recover premiums already funded into vesting.

#### Overdue fixed interest depends on an extension

- **Issue:** Repayment after expiry does not add overdue interest. A borrower can repay before an extension and avoid charges for the overdue interval.
- **Accepted:** Overdue premiums are charged when the loan is extended, not automatically at expiry or repayment.
- **Mitigation:** Keepers should extend overdue loans once the grace period permits. The contracts do not guarantee that extension happens before repayment.

### Floating interest and indexes

#### Floating premium allocation depends on checkpoint frequency

- **Issue:** More frequent realization can increase underwriting's share of the same debt growth at liquidity providers' expense.
- **Accepted:** Premium allocation depends on realization frequency. Underwriting rewards are distributed to eligible tranche holders by weight; the caller receives no separate reward.
- **Mitigation:** A keeper is intended to realize premiums regularly. That cadence is not enforced. Total premium still reconciles to reported debt growth.

#### Checkpoint timing can affect total floating interest

- **Issue:** Changing IRM checkpoint frequency can change total calculated debt, separately from how premiums are split between recipients.
- **Accepted:** Compounding uses a cubic approximation, so different checkpoint schedules need not produce exactly the same interest.
- **Mitigation:** Long elapsed periods are split into intervals of at most one year to limit approximation error per interval. This does not eliminate checkpoint dependence.

#### Index arithmetic still has finite bounds

- **Issue:** At very large index values, arithmetic can revert and block operations that depend on those indexes.
- **Accepted:** Indexes are not automatically rebased. Results must fit in `uint256`, and `rayDiv` still has a stricter intermediate-multiplication limit.
- **Mitigation:** Full-precision, half-up `rayMul` prevents intermediate multiplication overflow when the final result fits, covering index growth and supply averaging.

### Premium distribution and vesting

#### Late depositors earn premiums generated before entry

- **Issue:** Entering near premium funding can capture rewards without having provided capital throughout the earning interval or loan term.
- **Accepted:** Premiums reward current eligible balances as they vest. Old and new tranche shares have the same withdrawal and locking rules; neither group is guaranteed an exit.
- **Mitigation:** Configurable vesting spreads rewards over time. It does not require a minimum holding period or reserve rewards for historical holders.

#### Underwriter pools vest harvested premiums again

- **Issue:** Already-vested tranche premiums enter the Underwriter's vesting pot, where later pool depositors can earn them.
- **Accepted:** Underwriters claim tranche rewards only through manager-controlled `_report` calls. Immediate distribution would let someone enter just before a report, collect a share of accumulated rewards, and leave if liquidity permits. We vest again so earning those rewards requires continued participation.
- **Mitigation:** The curator controls the pool's vesting period. Later entrants can still earn, but the harvest is distributed over time rather than paid out immediately.

#### Borrowers earn part of their own fixed premium

- **Issue:** Newly borrowed cUSD can earn a share of the loan's upfront liquidity premium.
- **Accepted:** Borrowed tokens remain eligible for rewards. Holding them has an opportunity cost, but the resulting rebate can still be substantial.
- **Mitigation:** Premiums are shared across all opted-in cUSD holders, limiting the borrower's rebate to its proportional share. Other holders dilute that share, although it can remain large if the borrower dominates opted-in supply. Longer vesting spreads the rebate over time; the deployment default is 12 hours.

#### Premium rounding and capped claims can leave rewards unpaid

- **Issue:** Per-share rounding can leave funded rewards unclaimable. Separately, if a claim exceeds spendable premium, payment is capped and the unpaid entitlement is cleared.
- **Accepted:** Rounding dust can remain unclaimable, and capped claim shortfalls are not carried forward. Later funding does not restore a cleared entitlement.
- **Mitigation:** Underwriters below 1% of par reject new capital, preventing recapitalization from inflating share supply and magnifying rounding loss. The claim cap limits payouts to spendable premium and protects cUSD redemption escrow; it does not preserve unpaid claims.

### Underwriter and tranche accounting

#### Underwriter pricing can use stale tranche values

- **Issue:** After an unreported loss, a holder can redeem idle cash at an inflated price, leaving more loss for remaining holders. Stale marks can also overcharge entrants or dilute existing holders.
- **Accepted:** Redemptions use cached tranche values, including the default position. Only deposit and mint quotes value the default position live; other positions remain cached.
- **Mitigation:** Keepers should report changes promptly, but an exit can arrive first. Issuance previews can differ from cached conversion views and can revert if default-tranche valuation fails.

#### Donations affect tranche and Underwriter valuations

- **Issue:** Donated collateral affects tranche share prices and the Underwriter marks derived from them. Positive-share deposits remain subject to rounding.
- **Accepted:** No additional donation-specific protection is adopted. Both layers retain 1,000 dead shares, and zero-share deposits revert. These defenses do not establish that every donation strategy is unprofitable.

#### Default allocation can reduce Underwriter exit liquidity

- **Issue:** Withdrawing idle funds and depositing again allocates them to the default tranche, reducing immediate liquidity for remaining holders.
- **Accepted:** Deposits auto-allocate; exits pay only from idle balances.
- **Mitigation:** Curators can remove the default tranche or deallocate capital. Allocated or locked funds may delay exits.

#### Seeding an empty tranche costs the Underwriter pool

- **Issue:** An allocation into an empty tranche creates 1,000 permanent dead shares after pool issuance has been quoted, reducing pool NAV.
- **Accepted:** This one-time cost per newly funded tranche is borne through pool NAV. It is measured in smallest share units and is not necessarily charged solely to the new depositor.

### Liquidation and collateral pricing

#### Write-offs can leave healthy, unliquidatable debt

- **Issue:** A floating write-off can leave healthy residual debt. A nonzero buffer does not prevent this.
- **Accepted:** The guardian can write off unrecoverable debt even if the residual becomes unliquidatable.
- **Mitigation:** The 10-percentage-point minimum buffer prevents immediate renewed borrowing against unchanged collateral after a full floating write-off. Guardians should liquidate before writing off when the residual would become healthy; the buffer does not enforce that ordering.

#### Liquidation rounding can reduce collateral payouts

- **Issue:** Collateral payouts round down to token units, so a liquidator can receive less than the intended repayment-plus-bonus value.
- **Accepted:** Any residual value left after the liquidation waterfall is not refunded or deducted from the liquidator's cUSD repayment.
- **Mitigation:** Liquidators must account for collateral token precision when sizing repayments, especially small ones.

#### Unavailable collateral prices can block market operations

- **Issue:** If a funded tranche's price is unavailable, market borrowing, liquidation, and exits that require that price can revert.
- **Accepted:** These operations require valid prices and may stop until pricing is restored.
- **Mitigation:** The oracle tries a secondary source when the primary fails. Empty tranches do not need price valuation, and debt-free tranche exits remain available.

### Redemption queues

#### Queued redemptions remain exposed to losses and changing liquidity

- **Issue:** Queued shares earn no new premiums and remain exposed to losses. Previously claimable shares can become pending again if unlocked liquidity falls.
- **Accepted:** Requests record shares, not a fixed payout or permanently reserved assets. Value and availability are determined at claim time; requests cannot be cancelled.
- **Mitigation:** Rewards earned before queueing remain claimable. Instant exits avoid waiting where liquidity permits. Integrators must handle changing availability and claim reverts.

#### Many redemption requests can make aggregate claims expensive

- **Issue:** Aggregate claims collect and sort a controller's requests. Large request counts can make those calls too expensive to execute.
- **Accepted:** Request counts are uncapped, and others can transfer requests to a controller without its approval, including dust requests.
- **Mitigation:** Controllers can claim individual request IDs without sorting their full request list. This avoids the aggregate call but may require multiple transactions.

## Operating assumptions

- **Supported collateral:** The Vault assumes 1:1 token accounting. Fee-on-transfer and rebasing assets are unsupported and must be excluded during asset selection; deposits do not check for these token behaviors.
- **Curator trust:** Registering a tranche grants it Vault operator permissions over the Underwriter's balances. Curators must verify that it is a genuine protocol tranche using the correct asset and Vault; registration does not enforce those checks.
- **Shared borrower authority:** Borrowing operators within a market must be mutually trusted. Borrower permission allows `borrowMore` or `extend` on any eligible fixed loan ID, without a per-loan owner check. Credit capacity and collateral are shared across the market.
- **Deposit admission:** Tranche and Underwriter deposit permissions apply to the caller. Admitted callers can deposit for any receiver, and shares remain transferable. Admission does not restrict who can hold shares.
- **Tranche capital caps:** `maxCapital` limits a tranche's contribution to borrowing capacity, not deposits or loss exposure. Collateral above the cap remains available to the liquidation waterfall.
- **Governance and upgrades:** Privileged roles are trusted to configure permissions, economic parameters and implementations correctly. Upgrades must preserve existing storage and accounting.
- **Operational availability:** Keepers, guardians and authorized liquidators must perform reporting, premium realization, overdue extensions and liquidation promptly. The contracts do not guarantee a response time.
- **Temporary pause:** The cUSD pause is intended as a temporary emergency measure. Guardians must lift it when safe; it does not expire automatically. Pausing blocks minting and burning, including borrowing, repayment, liquidation and cUSD redemption. Transfers remain enabled, while interest accrual and loan expiry continue.
- **Oracle accuracy:** Configured feeds must report accurate prices in the expected units. A fresh, positive but incorrect primary price is accepted; the secondary source is a fallback, not a cross-check.
- **Reserve asset peg:** Minting treats one whole reserve token as one cUSD. A reserve token's dollar depeg does not automatically change that conversion.
- **Reserve liquidity and custody:** Invested reserves depend on the external vault and keeper recalls. Redemptions do not automatically recall investments, and changing the reserve-vault address does not migrate existing funds.
- **Approved operators:** Users must trust approved redemption operators, which can direct claim payouts. Any zap acting as an operator must independently authenticate the user's instructions and intended recipient.
