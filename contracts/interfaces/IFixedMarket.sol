// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "./IBaseMarket.sol";

/// @title IFixedMarket
/// @author kexley, Cap Labs
/// @notice Interface for fixed interest rate market
interface IFixedMarket is IBaseMarket {
    /// @notice Invalid term entered for the loan
    error InvalidTerm();

    /// @notice Invalid term limits, the minimum must not exceed a non-zero maximum
    error InvalidTermLimits();

    /// @notice Loan has not yet passed its expiry plus grace period
    error StillInGracePeriod();

    /// @notice Loan has expired, cannot be extended
    error LoanExpired();

    /// @notice Term limits were updated
    /// @param maximumTermLimit The new maximum term of a loan
    /// @param minimumTermLimit The new minimum term of a loan
    event SetTermLimits(uint256 maximumTermLimit, uint256 minimumTermLimit);

    /// @notice Borrowed assets from the market
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param term The term of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @param premium The charged premium for the loan
    event BorrowFixed(uint256 indexed id, address indexed recipient, uint256 term, uint256 principal, uint256 premium);

    /// @notice Extended the term of a loan
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @param premium The charged premium for the extended term
    event ExtendFixed(uint256 indexed id, uint256 extension, uint256 premium);

    /// @notice Repaid assets to the loan
    /// @param id The id of the loan
    /// @param repaid The amount of assets repaid
    event RepayFixed(uint256 indexed id, uint256 repaid);

    /// @notice Liquidated assets from the market
    /// @param id The id of the loan
    /// @param sender The sender of the liquidation request
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets liquidated
    /// @param assetsSlashed The amount of assets slashed
    event LiquidateFixed(
        uint256 indexed id, address indexed sender, address indexed recipient, uint256 amount, uint256 assetsSlashed
    );

    /// @notice Initialize the market
    /// @param authority The authority of the market
    /// @param registry The registry providing shared market configuration
    /// @param name The name of the market
    /// @param maximumTermLimit The maximum term of a loan
    /// @param minimumTermLimit The minimum term of a loan
    /// @param grace The grace period after expiry for admin extensions
    function initialize(
        address authority,
        address registry,
        string memory name,
        uint256 maximumTermLimit,
        uint256 minimumTermLimit,
        uint256 grace
    ) external;

    /// @notice Borrow assets from the market
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @param term The term of the borrowed assets
    /// @return id The id of the loan
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrow(address recipient, uint256 principal, uint256 term)
        external
        returns (uint256 id, uint256 actualPrincipal);

    /// @notice Borrow additional assets against an existing loan
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrowMore(uint256 id, address recipient, uint256 principal) external returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @param id The id of the loan
    /// @param amount The amount of assets to repay
    /// @return repaid The actual amount of assets repaid
    function repay(uint256 id, uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @param id The id of the loan
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate
    /// @return repaid The actual amount of assets repaid
    /// @return assetsSlashed The amount of assets slashed
    function liquidate(uint256 id, address recipient, uint256 amount)
        external
        returns (uint256 repaid, uint256 assetsSlashed);

    /// @notice Extend the term of a loan
    /// @dev A live loan can be extended up to the room left under the maximum term. An expired loan
    /// is rolled a full `extension` forward from now, so the arrears are added on top of the
    /// requested term and charged a premium; only the requested term is bound by the term limits.
    /// Passing `type(uint256).max` takes the largest extension available in either case.
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @return actualExtension The actual extension of the term
    function extend(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Roll an overdue loan forward and charge it a premium for the overdue period
    /// @dev This is how an overdue loan is handled rather than by liquidation, which would take
    /// collateral from the underwriters instead of charging the borrower. Only callable once the
    /// loan is past its expiry plus grace period, at which point the keeper rolls it a full
    /// `extension` forward from now and the borrower's debt grows by the premium on the arrears
    /// plus the new term. Health is not checked: an overdue loan must be rollable even when the
    /// market is already unhealthy.
    /// @param id The id of the loan
    /// @param extension The new term to roll the loan forward by
    /// @return actualExtension The arrears plus the new term
    function extendAdmin(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Write off a loan's share of the market's unrecoverable debt as bad debt
    /// @dev Callable at any time, not just once the tranches are empty, because a liquidation that
    /// is unprofitable never happens and would otherwise let the shortfall compound. The amount is
    /// derived from the tranches rather than supplied: it is the loan's debt capped at the market
    /// wide {unrecoverableDebt}, so the guardian chooses which loans absorb the shortfall but can
    /// never write off more than the collateral shortfall in total.
    /// @param id The id of the loan
    /// @return amount The amount of debt written off
    function writeOff(uint256 id) external returns (uint256 amount);

    /// @notice Set the term limits for new loans
    /// @param maximumTermLimit The maximum term of a loan, must be non-zero
    /// @param minimumTermLimit The minimum term of a loan, must not exceed the maximum
    function setTermLimits(uint256 maximumTermLimit, uint256 minimumTermLimit) external;

    /// @notice Get the liquidity and underwriter premiums
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premium(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the available credit for a term, discounted so that the principal plus its
    /// upfront premium fits inside the credit limit
    /// @dev The discount uses the liquidity rate as it stands now. Borrowing mints credit-backed
    /// stablecoin, which raises utilization and so the liquidity rate, and the premium is charged
    /// at that higher post-mint rate. Final debt can therefore exceed the credit limit by the width
    /// of that rate move, which is largest on a market with little unlocked supply. The gap is
    /// bounded by the ltv-to-lt corridor and cannot by itself make the market unhealthy.
    /// @param term The term of the loan
    /// @return credit The available credit
    function availableCredit(uint256 term) external view returns (uint256 credit);

    /// @notice Get the maximum term limit
    /// @return maximumTermLimit The maximum term limit
    function maximumTermLimit() external view returns (uint256 maximumTermLimit);

    /// @notice Get the minimum term limit
    /// @return minimumTermLimit The minimum term limit
    function minimumTermLimit() external view returns (uint256 minimumTermLimit);

    /// @notice Get the grace period
    /// @return grace The grace period
    function grace() external view returns (uint256 grace);

    /// @notice Get the number of all loans, including fully repaid loans
    /// @return loanCount The total number of loans
    function loanCount() external view returns (uint256 loanCount);

    /// @notice Get the debt of a loan
    /// @param id The id of the loan
    /// @return debt The debt of the loan
    function debt(uint256 id) external view returns (uint256 debt);

    /// @notice Get the expiry of a loan
    /// @param id The id of the loan
    /// @return expiry The expiry of the loan
    function expiry(uint256 id) external view returns (uint256 expiry);
}
