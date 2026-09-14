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

    /// @notice No loan was created at this id
    /// @param id The id that is outside `[0, loanCount)`
    error LoanNotFound(uint256 id);

    /// @notice The loan was fully repaid and cannot reopen
    /// @param id The closed loan
    error LoanClosed(uint256 id);

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
    /// @dev Premium is {premiumForBorrow}. Splitting a draw can cheapen the total;
    /// borrowers are permissioned and that is not acceptable use.
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @param term The term of the borrowed assets
    /// @return id The id of the loan
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrow(address recipient, uint256 principal, uint256 term)
        external
        returns (uint256 id, uint256 actualPrincipal);

    /// @notice Borrow additional assets against an existing loan
    /// @dev `id` must be in `[0, loanCount)` and still carry debt. A fully repaid
    /// loan stays enumerable but cannot reopen; open a new loan with {borrow}.
    /// Priced as a new {premiumForBorrow} on this add-on, so it can be cheaper
    /// than drawing the same total in one go. Borrowers are permissioned; splitting
    /// to cheapen the premium is not acceptable use.
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets
    /// @return actualPrincipal The actual principal amount of the borrowed assets
    function borrowMore(uint256 id, address recipient, uint256 principal) external returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @dev Burns the recorded amount. Arrears accrue only when {extend} or {extendAdmin} runs
    /// after expiry; a keeper must call that after the grace period.
    /// @param id The id of the loan. Must be in `[0, loanCount)`.
    /// @param amount The amount of assets to repay
    /// @return repaid The actual amount of assets repaid
    function repay(uint256 id, uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @param id The id of the loan. Must be in `[0, loanCount)`.
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate
    /// @return repaid The actual amount of assets repaid
    /// @return assetsSlashed The amount of assets slashed
    function liquidate(uint256 id, address recipient, uint256 amount)
        external
        returns (uint256 repaid, uint256 assetsSlashed);

    /// @notice Extend the term of a loan
    /// @dev Live loans can grow only up to the current {maximumTermLimit}. If that limit was
    /// lowered below remaining term, there is no room and the call reverts {InvalidTerm}; the
    /// existing expiry is unchanged. Expired loans roll from now and charge arrears.
    /// `id` must be in `[0, loanCount)` and still carry debt.
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @return actualExtension The actual extension of the term
    function extend(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Roll an overdue loan forward and charge premium for the arrears
    /// @dev Health is not checked potentially making loan liquidatable.
    /// `id` must be in `[0, loanCount)` and still carry debt.
    /// @param id The id of the loan
    /// @param extension The new term to roll the loan forward by
    /// @return actualExtension The arrears plus the new term
    function extendAdmin(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Write off this loan's share of {unrecoverableDebt}
    /// @dev Capped at the market-wide shortfall. `id` must be in `[0, loanCount)`.
    /// @param id The id of the loan
    /// @return amount The amount of debt written off
    function writeOff(uint256 id) external returns (uint256 amount);

    /// @notice Set the term limits for new loans
    /// @param maximumTermLimit The maximum term of a loan, must be non-zero
    /// @param minimumTermLimit The minimum term of a loan, must not exceed the maximum
    function setTermLimits(uint256 maximumTermLimit, uint256 minimumTermLimit) external;

    /// @notice Premium an extension would be charged
    /// @dev At current rates. Use {premiumForBorrow} for a new draw.
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premiumForExtension(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Premium a new borrow would be charged
    /// @dev On this principal at the rate after it is minted. Earlier draws already
    /// sit in the credit-backed supply, so a later draw is dearer per token, but
    /// early slices miss the high rate the full principal would have paid. Splitting
    /// can therefore cheapen the total versus one draw. That is expected. Borrowers
    /// are permissioned; splitting to reduce premium is not acceptable use.
    /// `type(uint256).max` and anything above {maximumTermLimit} quote at the maximum.
    /// @param principal The principal of the loan
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premiumForBorrow(uint256 principal, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice A principal borrowable over a term, leaving room for the upfront premium
    /// @dev Sized so principal plus {premiumForBorrow} fits in the raw {IBaseMarket-availableCredit}.
    /// `type(uint256).max` and anything above {maximumTermLimit} quote at the maximum.
    /// May be below the exact maximum.
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
