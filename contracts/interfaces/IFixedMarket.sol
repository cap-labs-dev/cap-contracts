// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "./IBaseMarket.sol";

/// @title IFixedMarket
/// @author kexley, Cap Labs
/// @notice Interface for fixed interest rate market
interface IFixedMarket is IBaseMarket {
    /// @notice Invalid term entered for the loan
    error InvalidTerm();

    /// @notice Still in grace period for the loan
    error StillInGracePeriod();

    /// @notice Loan has expired, cannot be extended
    error LoanExpired();

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
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @return actualExtension The actual extension of the term
    function extend(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Extend the term of a loan by the admin
    /// @param id The id of the loan
    /// @param extension The extension of the term
    /// @return actualExtension The actual extension of the term
    function extendAdmin(uint256 id, uint256 extension) external returns (uint256 actualExtension);

    /// @notice Get the liquidity and underwriter premiums
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function premium(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium);

    /// @notice Get the available credit for a term
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
