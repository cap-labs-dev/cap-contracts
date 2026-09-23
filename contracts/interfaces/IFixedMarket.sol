// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "./IBaseMarket.sol";

/// @title IFixedMarket
/// @author kexley, Cap Labs
/// @notice Interface for the fixed interest rate market
interface IFixedMarket is IBaseMarket {
    /// @notice The term entered for the loan is invalid
    error InvalidTerm();

    /// @notice The term limits are invalid, the minimum must not exceed a non-zero maximum
    error InvalidTermLimits();

    /// @notice The loan has not yet passed its expiry plus grace period
    error StillInGracePeriod();

    /// @notice The loan has expired and additional borrowing is unavailable
    /// @dev Used by {borrowMore}. Expired loans can still {extend} or {extendAdmin}.
    error LoanExpired();

    /// @notice The loan was not created at this id
    /// @param id The id that is outside `[0, loanCount)`
    error LoanNotFound(uint256 id);

    /// @notice The loan was fully repaid and cannot reopen
    /// @param id The closed loan
    error LoanClosed(uint256 id);

    /// @notice The draw's combined liquidity and underwriting premium exceeds the caller's limit
    /// @param premium The premium calculated for the draw, in cUSD units (18 decimals)
    /// @param maxPremium The maximum premium the caller accepts, in cUSD units (18 decimals)
    error PremiumExceedsLimit(uint256 premium, uint256 maxPremium);

    /// @notice Emitted when the term limits are updated
    /// @param maximumTermLimit The new maximum term of a loan
    /// @param minimumTermLimit The new minimum term of a loan
    event SetTermLimits(uint256 maximumTermLimit, uint256 minimumTermLimit);

    /// @notice Emitted when assets are borrowed from the market
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param term The term of the borrowed assets
    /// @param principal The principal amount of the borrowed assets, in stablecoin units (18 decimals)
    /// @param premium The charged premium for the loan, in stablecoin units (18 decimals)
    event BorrowFixed(uint256 indexed id, address indexed recipient, uint256 term, uint256 principal, uint256 premium);

    /// @notice Emitted when additional principal is drawn on an existing loan
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param term The remaining term at the time of the draw, in seconds
    /// @param principal The principal added, in stablecoin units (18 decimals)
    /// @param premium The charged premium for the add-on, in stablecoin units (18 decimals)
    event BorrowMoreFixed(
        uint256 indexed id, address indexed recipient, uint256 term, uint256 principal, uint256 premium
    );

    /// @notice Emitted when the term of a loan is extended
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @param premium The charged premium for the extended term, in stablecoin units (18 decimals)
    event ExtendFixed(uint256 indexed id, uint256 extension, uint256 premium);

    /// @notice Emitted when assets are repaid to the loan
    /// @param id The id of the loan
    /// @param repaid The amount of assets repaid, in stablecoin units (18 decimals)
    event RepayFixed(uint256 indexed id, uint256 repaid);

    /// @notice Emitted when assets are liquidated from the market
    /// @param id The id of the loan
    /// @param sender The sender of the liquidation request
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of debt repaid, in stablecoin units (18 decimals)
    /// @param valueSlashed The USD value of collateral delivered, 18 decimals, possibly across tokens
    event LiquidateFixed(
        uint256 indexed id, address indexed sender, address indexed recipient, uint256 amount, uint256 valueSlashed
    );

    /// @notice Emitted when unrecoverable debt on a loan is written off
    /// @dev Complements the market-level {IBaseMarket-WriteOff}, which does not name the loan.
    /// @param id The id of the loan
    /// @param amount The amount of debt written off, in stablecoin units (18 decimals)
    /// @param remainingDebt The loan's debt after the write off, in stablecoin units (18 decimals)
    event WriteOffFixed(uint256 indexed id, uint256 amount, uint256 remainingDebt);

    /// @notice Initialize the market
    /// @dev Term limits must satisfy {setTermLimits}. `grace` is the delay before {extendAdmin}.
    /// @param authority The access manager address
    /// @param registry The registry providing shared market configuration
    /// @param name The name of the market
    /// @param maximumTermLimit The maximum term of a loan, must be non-zero
    /// @param minimumTermLimit The minimum term of a loan, must not exceed the maximum
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
    /// @dev Premium is {premiumForBorrow}. `type(uint256).max` fills the maximum term;
    /// a finite term outside the band reverts {InvalidTerm}.
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets, in stablecoin units (18 decimals), or
    /// `type(uint256).max` for the computed available principal over `term`. That size may sit
    /// below the exact maximum.
    /// @param term The term of the borrowed assets
    /// @param maxPremium Maximum combined liquidity and underwriting premium, in cUSD units (18 decimals).
    /// Use `type(uint256).max` for no cap. Reverts {PremiumExceedsLimit} if exceeded.
    /// @return id The id of the loan
    /// @return actualPrincipal The actual principal amount of the borrowed assets, in stablecoin units (18 decimals)
    function borrow(address recipient, uint256 principal, uint256 term, uint256 maxPremium)
        external
        returns (uint256 id, uint256 actualPrincipal);

    /// @notice Borrow additional assets against an existing loan
    /// @dev `id` must still carry debt. A fully repaid loan stays enumerable but cannot
    /// reopen; open a new loan with {borrow}. Premium is {premiumForBorrow} on the
    /// remaining term. Reverts {LoanExpired} at or after expiry, {InvalidTerm} if the
    /// remainder is below {minimumTermLimit}.
    /// @param id The id of the loan
    /// @param recipient The recipient of the borrowed assets
    /// @param principal The principal amount of the borrowed assets, in stablecoin units (18 decimals), or
    /// `type(uint256).max` for the computed available add-on over the remaining term. That size may
    /// sit below the exact maximum.
    /// @param maxPremium Maximum combined liquidity and underwriting premium for this add-on, in cUSD units
    /// (18 decimals). Use `type(uint256).max` for no cap. Reverts {PremiumExceedsLimit} if exceeded.
    /// @return actualPrincipal The actual principal amount of the borrowed assets, in stablecoin units (18 decimals)
    function borrowMore(uint256 id, address recipient, uint256 principal, uint256 maxPremium)
        external
        returns (uint256 actualPrincipal);

    /// @notice Repay assets to the market
    /// @dev Burns the recorded amount. Arrears accrue only when {extend} or {extendAdmin} runs
    /// after expiry; a keeper must call that after the grace period.
    /// @param id The id of the loan. Must be in `[0, loanCount)`.
    /// @param amount The amount of assets to repay, in stablecoin units (18 decimals)
    /// @return repaid The actual amount of assets repaid, in stablecoin units (18 decimals)
    function repay(uint256 id, uint256 amount) external returns (uint256 repaid);

    /// @notice Liquidate assets from the market
    /// @dev `id` must be in `[0, loanCount)`. Reverts {Healthy} when the market is not
    /// liquidatable. `amount` of `type(uint256).max` clears as much as {maxLiquidatable}.
    /// @param id The id of the loan
    /// @param recipient The recipient of the liquidated assets
    /// @param amount The amount of assets to liquidate, in stablecoin units (18 decimals)
    /// @return repaid The actual amount of assets repaid, in stablecoin units (18 decimals)
    /// @return valueSlashed The USD value of collateral delivered, 18 decimals, possibly across tokens
    function liquidate(uint256 id, address recipient, uint256 amount)
        external
        returns (uint256 repaid, uint256 valueSlashed);

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
    /// @dev Health is not checked, so the loan may become liquidatable.
    /// `id` must be in `[0, loanCount)` and still carry debt.
    /// @param id The id of the loan
    /// @param extension The new term to roll the loan forward by
    /// @return actualExtension The arrears plus the new term
    function extendAdmin(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Write off this loan's share of {unrecoverableDebt}
    /// @dev The market must be unhealthy before the write-off. Capped at the market-wide shortfall;
    /// collateral is not slashed. Remaining market debt may be healthy, so continued liquidatability
    /// is not guaranteed. Borrowing remains subject to {creditLimit}; the market is not paused.
    /// `id` must be in `[0, loanCount)`.
    /// @param id The id of the loan
    /// @return amount The amount of debt written off, in stablecoin units (18 decimals)
    function writeOff(uint256 id) external returns (uint256 amount);

    /// @notice Set the term limits for new loans
    /// @dev Existing loans keep their expiry. A lowered maximum that sits below a live
    /// remaining term leaves that loan with no room to {extend}.
    /// @param maximumTermLimit The maximum term of a loan, must be non-zero
    /// @param minimumTermLimit The minimum term of a loan, must not exceed the maximum
    function setTermLimits(uint256 maximumTermLimit, uint256 minimumTermLimit) external;

    /// @notice Get the premium an extension would be charged
    /// @dev At current rates, with no extra mint. `term` is used as given so an
    /// arrears-inclusive roll can exceed {maximumTermLimit}. Use {premiumForBorrow}
    /// for a new draw.
    /// @param chargeableDebt The amount of debt that a premium is being charged on, in stablecoin units (18 decimals)
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium, in stablecoin units (18 decimals)
    /// @return underwriterPremium The underwriter premium, in stablecoin units (18 decimals)
    function premiumForExtension(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the premium a new borrow would be charged
    /// @dev On this principal at the rate after it is minted. Earlier draws already
    /// sit in the credit-backed supply, so a later draw is dearer per token, but
    /// early slices miss the high rate the full principal would have paid. Splitting
    /// can therefore cheapen the total versus one draw. That is expected. Borrowers
    /// are permissioned; splitting to reduce premium is not acceptable use.
    /// `type(uint256).max` and anything above {maximumTermLimit} quote at the maximum.
    /// @param principal The principal of the loan, in stablecoin units (18 decimals)
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium, in stablecoin units (18 decimals)
    /// @return underwriterPremium The underwriter premium, in stablecoin units (18 decimals)
    function premiumForBorrow(uint256 principal, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get a principal borrowable over a term, leaving room for the upfront premium
    /// @dev Sized so principal plus {premiumForBorrow} fits in the raw {IBaseMarket-availableCredit}.
    /// `type(uint256).max` and anything above {maximumTermLimit} quote at the maximum.
    /// May be below the exact maximum.
    /// @param term The term of the loan
    /// @return credit The available credit in USD (18 decimals)
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
    /// @return debt The debt of the loan, in stablecoin units (18 decimals)
    function debt(uint256 id) external view returns (uint256 debt);

    /// @notice Get the expiry of a loan
    /// @param id The id of the loan
    /// @return expiry The expiry of the loan
    function expiry(uint256 id) external view returns (uint256 expiry);
}
