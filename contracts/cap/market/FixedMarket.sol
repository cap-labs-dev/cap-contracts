// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { MathUtils } from "../../utils/MathUtils.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import { BaseMarket } from "./BaseMarket.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FixedMarket
/// @author kexley, Cap Labs
/// @notice Fixed interest rate market
contract FixedMarket layout at erc7201("cap.storage.FixedMarket") is IFixedMarket, BaseMarket {
    using WadRayMath for uint256;

    /// @inheritdoc IFixedMarket
    uint256 public maximumTermLimit;

    /// @inheritdoc IFixedMarket
    uint256 public minimumTermLimit;

    /// @inheritdoc IFixedMarket
    uint256 public grace;

    /// @inheritdoc IFixedMarket
    uint256 public loanCount;

    /// @inheritdoc IFixedMarket
    mapping(uint256 => uint256) public debt;

    /// @inheritdoc IFixedMarket
    mapping(uint256 => uint256) public expiry;

    /// @dev Aggregate outstanding debt across all loans
    uint256 private _totalDebt;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFixedMarket
    function initialize(
        address _authority,
        address _registry,
        string memory _name,
        uint256 _maximumTermLimit,
        uint256 _minimumTermLimit,
        uint256 _grace
    ) external initializer {
        __BaseMarket_init(_authority, _registry, _name);
        _setTermLimits(_maximumTermLimit, _minimumTermLimit);
        grace = _grace;
    }

    /// @inheritdoc IFixedMarket
    function setTermLimits(uint256 _maximumTermLimit, uint256 _minimumTermLimit) external restricted nonReentrant {
        _setTermLimits(_maximumTermLimit, _minimumTermLimit);
    }

    /// @inheritdoc IFixedMarket
    function borrow(address recipient, uint256 principal, uint256 term)
        external
        restricted
        nonReentrant
        returns (uint256 id, uint256 actualPrincipal)
    {
        if (term == type(uint256).max) term = maximumTermLimit;
        else if (term > maximumTermLimit || term < minimumTermLimit) revert InvalidTerm();
        id = loanCount++;
        expiry[id] = block.timestamp + term;
        actualPrincipal = _borrow(id, recipient, principal, term);
    }

    /// @inheritdoc IFixedMarket
    function borrowMore(uint256 id, address recipient, uint256 principal)
        external
        restricted
        nonReentrant
        returns (uint256 actualPrincipal)
    {
        _requireOpenLoan(id);
        if (block.timestamp >= expiry[id]) revert LoanExpired();
        uint256 term = expiry[id] - block.timestamp;
        if (term < minimumTermLimit) revert InvalidTerm();
        actualPrincipal = _borrow(id, recipient, principal, term);
    }

    /// @inheritdoc IFixedMarket
    function extend(uint256 id, uint256 extension) external restricted nonReentrant returns (uint256 actualExtension) {
        _requireOpenLoan(id);
        uint256 previousExpiry = expiry[id];
        if (block.timestamp >= previousExpiry) {
            actualExtension = _rollFromNow(previousExpiry, extension);
        } else {
            uint256 remainingTerm = previousExpiry - block.timestamp;
            // a lowered maximum can sit below a grandfathered remaining term; that loan keeps
            // its expiry, it just has no room to grow
            if (remainingTerm >= maximumTermLimit) revert InvalidTerm();
            uint256 remaining = maximumTermLimit - remainingTerm;
            if (extension == type(uint256).max) actualExtension = remaining;
            else if (extension > remaining) revert InvalidTerm();
            else actualExtension = extension;
        }

        _extend(id, actualExtension);
        if (healthiness() < 1e27) revert Unhealthy();
    }

    /// @inheritdoc IFixedMarket
    function extendAdmin(uint256 id, uint256 extension)
        external
        restricted
        nonReentrant
        returns (uint256 actualExtension)
    {
        _requireOpenLoan(id);
        uint256 previousExpiry = expiry[id];
        if (block.timestamp < previousExpiry + grace) revert StillInGracePeriod();
        actualExtension = _rollFromNow(previousExpiry, extension);
        _extend(id, actualExtension);
    }

    /// @inheritdoc IFixedMarket
    function repay(uint256 id, uint256 amount) external nonReentrant returns (uint256 repaid) {
        _requireLoan(id);
        repaid = _debtCheck(debt[id], amount);
        debt[id] -= repaid;
        _totalDebt -= repaid;
        _repay(repaid);
        emit RepayFixed(id, repaid);
    }

    /// @inheritdoc IFixedMarket
    function liquidate(uint256 id, address recipient, uint256 amount)
        external
        restricted
        nonReentrant
        returns (uint256 repaid, uint256 assetsSlashed)
    {
        _requireLoan(id);
        (repaid, assetsSlashed) = _liquidate(recipient, _debtCheck(debt[id], amount));
        debt[id] -= repaid;
        _totalDebt -= repaid;
        emit LiquidateFixed(id, msg.sender, recipient, repaid, assetsSlashed);
    }

    /// @inheritdoc IFixedMarket
    function writeOff(uint256 id) external restricted nonReentrant returns (uint256 amount) {
        _requireLoan(id);
        uint256 loanDebt = debt[id];
        uint256 unrecoverable = unrecoverableDebt();
        amount = loanDebt < unrecoverable ? loanDebt : unrecoverable;
        // record against the pre-write-off debt, since that is what bounds the write off
        _writeOff(amount);
        debt[id] = loanDebt - amount;
        _totalDebt -= amount;
    }

    /// @inheritdoc IBaseMarket
    function totalDebt() public view override(BaseMarket, IBaseMarket) returns (uint256 marketDebt) {
        marketDebt = _totalDebt;
    }

    /// @inheritdoc IFixedMarket
    function premiumForExtension(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        (liquidityPremium, underwriterPremium) = _premiumStillToMint(chargeableDebt, term, 0);
    }

    /// @inheritdoc IFixedMarket
    function premiumForBorrow(uint256 principal, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        (liquidityPremium, underwriterPremium) = _premiumStillToMint(principal, _quoteTerm(term), principal);
    }

    /// @inheritdoc IFixedMarket
    function availableCredit(uint256 term) public view returns (uint256 credit) {
        credit = _principalFor(availableCredit(), _quoteTerm(term));
    }

    /// @dev A loan created by {borrow}, including fully repaid ones.
    /// @param id The loan id
    function _requireLoan(uint256 id) internal view {
        if (id >= loanCount) revert LoanNotFound(id);
    }

    /// @dev An existing loan that still carries debt. Fully repaid loans stay in
    /// `[0, loanCount)` for enumeration but cannot reopen.
    /// @param id The loan id
    function _requireOpenLoan(uint256 id) internal view {
        _requireLoan(id);
        if (debt[id] == 0) revert LoanClosed(id);
    }

    /// @dev Borrow the principal
    /// @param id The id of the loan
    /// @param recipient The address to borrow to
    /// @param principal The principal of the loan
    /// @param term The term of the loan
    /// @return actualPrincipal The principal actually drawn
    function _borrow(uint256 id, address recipient, uint256 principal, uint256 term)
        internal
        returns (uint256 actualPrincipal)
    {
        uint256 limit = availableCredit();
        actualPrincipal = principal == type(uint256).max ? _principalFor(limit, term) : principal;
        if (actualPrincipal == 0) revert InvalidPrincipal();

        (uint256 liquidityPremium, uint256 underwriterPremium) =
            _premiumStillToMint(actualPrincipal, term, actualPrincipal);
        if (actualPrincipal + liquidityPremium + underwriterPremium > limit) revert InsufficientLiquidity();

        debt[id] += actualPrincipal;
        _totalDebt += actualPrincipal;
        _borrow(recipient, actualPrincipal);
        uint256 chargedPremium = _applyPremium(id, liquidityPremium, underwriterPremium);
        // credit is min(ltv, lt) against active capital; the threshold is lt against total. A full
        // draw can land on health of one when those match. The Unhealthy assert is for the premium
        // stacked on top, and for any active < total gap. {extend} asserts the same after its charge
        if (healthiness() < 1e27) revert Unhealthy();
        emit BorrowFixed(id, recipient, term, actualPrincipal, chargedPremium);
    }

    /// @dev Rates after `mintAmount` of credit-backed supply is minted.
    /// @param term The term of the loan in seconds, already capped at the maximum
    /// @param mintAmount The credit-backed supply still to be minted before the charge
    /// @return liquidityRate The liquidity rate per year in ray decimals
    /// @return underwriterRate The underwriter rate per year in ray decimals
    function _ratesStillToMint(uint256 term, uint256 mintAmount)
        internal
        view
        returns (uint256 liquidityRate, uint256 underwriterRate)
    {
        (liquidityRate, underwriterRate) =
            IInterestRateModel(irm()).fixedRatesAfterMint(address(this), term.rayDiv(maximumTermLimit), mintAmount);
        liquidityRate = liquidityRate.rayMul(marketMultiplier());
    }

    /// @dev The premium on `chargeableDebt` over `term`, priced per {_ratesStillToMint}
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan in seconds
    /// @param mintAmount The credit-backed supply still to be minted before the charge
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function _premiumStillToMint(uint256 chargeableDebt, uint256 term, uint256 mintAmount)
        internal
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        (uint256 liquidityRate, uint256 underwriterRate) = _ratesStillToMint(term, mintAmount);
        (liquidityPremium, underwriterPremium) = _premium(chargeableDebt, term, liquidityRate, underwriterRate);
    }

    /// @dev Combined liquidity and underwriter rate after `mintAmount` is minted.
    function _termRate(uint256 term, uint256 mintAmount) internal view returns (uint256 rate) {
        (uint256 liquidityRate, uint256 underwriterRate) = _ratesStillToMint(term, mintAmount);
        rate = liquidityRate + underwriterRate;
    }

    /// @dev A principal that, with its borrow premium, fits in `limit`. Invert at today's
    /// rate, then scale by `limit/cost` if the real quote is heavier. Four passes is enough
    /// because cost is nearly linear in principal. May sit below the exact maximum.
    function _principalFor(uint256 limit, uint256 term) internal view returns (uint256 principal) {
        if (limit == 0) return 0;

        principal = _principalWithin(limit, term, _termRate(term, 0));
        if (principal > limit) principal = limit;

        for (uint256 i; i < 4; ++i) {
            uint256 cost = _borrowCost(principal, term);
            if (cost <= limit) return principal;

            uint256 next = Math.mulDiv(principal, limit, cost);
            if (next == 0 || next >= principal) return 0;
            principal = next;
        }
        return 0;
    }

    /// @dev Principal plus the premium that draw would be charged.
    function _borrowCost(uint256 principal, uint256 term) internal view returns (uint256 cost) {
        (uint256 liquidityPremium, uint256 underwriterPremium) = _premiumStillToMint(principal, term, principal);
        cost = principal + liquidityPremium + underwriterPremium;
    }

    /// @dev Invert `principal + principal * term * rate / year = limit` at a constant rate.
    function _principalWithin(uint256 limit, uint256 term, uint256 rate) internal pure returns (uint256 principal) {
        principal = Math.mulDiv(limit, 1e27, 1e27 + Math.mulDiv(term, rate, MathUtils.SECONDS_PER_YEAR));
    }

    /// @dev `type(uint256).max` and anything above the maximum quote at the maximum.
    /// {borrow} still rejects a finite term outside the band.
    function _quoteTerm(uint256 term) internal view returns (uint256 quoted) {
        quoted = term == type(uint256).max || term > maximumTermLimit ? maximumTermLimit : term;
    }

    /// @dev Validate the term limits and store them
    /// @param _maximumTermLimit The maximum term of a loan
    /// @param _minimumTermLimit The minimum term of a loan
    function _setTermLimits(uint256 _maximumTermLimit, uint256 _minimumTermLimit) internal {
        // rates divide the term by the maximum, and a minimum above the maximum makes every
        // term invalid
        if (_maximumTermLimit == 0 || _minimumTermLimit > _maximumTermLimit) revert InvalidTermLimits();
        maximumTermLimit = _maximumTermLimit;
        minimumTermLimit = _minimumTermLimit;
        emit SetTermLimits(_maximumTermLimit, _minimumTermLimit);
    }

    /// @dev Size an expired-loan extension. Limits bound the requested term; arrears are added on top.
    /// @param previousExpiry The expiry the loan is being rolled from
    /// @param extension The requested new term, or `type(uint256).max` for the maximum
    /// @return actualExtension The arrears plus the requested term
    function _rollFromNow(uint256 previousExpiry, uint256 extension) internal view returns (uint256 actualExtension) {
        if (extension == type(uint256).max) actualExtension = maximumTermLimit;
        else if (extension > maximumTermLimit || extension < minimumTermLimit) revert InvalidTerm();
        else actualExtension = extension;
        actualExtension += block.timestamp - previousExpiry;
    }

    /// @dev Extend the loan
    /// @param id The id of the loan
    /// @param extension The extension of the loan
    function _extend(uint256 id, uint256 extension) internal {
        expiry[id] += extension;
        uint256 chargedPremium = _chargePremiumForTerm(id, debt[id], extension);
        emit ExtendFixed(id, extension, chargedPremium);
    }

    /// @dev Charge an extension. Mints nothing; {averageUtilizationAfterMint} still folds
    /// in unsmoothed credit, so a same-block borrow is in the rate the extension pays.
    function _chargePremiumForTerm(uint256 id, uint256 chargeableDebt, uint256 term)
        internal
        returns (uint256 chargedPremium)
    {
        (uint256 liquidityPremium, uint256 underwriterPremium) = _premiumStillToMint(chargeableDebt, term, 0);
        chargedPremium = _applyPremium(id, liquidityPremium, underwriterPremium);
    }

    /// @dev Record a computed premium on the loan and mint it
    /// @param id The id of the loan
    /// @param liquidityPremium The liquidity premium
    /// @param underwriterPremium The underwriter premium
    /// @return chargedPremium The amount of premium that was charged
    function _applyPremium(uint256 id, uint256 liquidityPremium, uint256 underwriterPremium)
        internal
        returns (uint256 chargedPremium)
    {
        chargedPremium = liquidityPremium + underwriterPremium;
        debt[id] += chargedPremium;
        _totalDebt += chargedPremium;
        _chargePremium(liquidityPremium, underwriterPremium);
    }

    /// @dev Premium on `chargeableDebt` over `term`. Rates are annualized.
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan in seconds
    /// @param liquidityRate The liquidity rate per year in ray decimals
    /// @param underwriterRate The underwriter rate per year in ray decimals
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function _premium(uint256 chargeableDebt, uint256 term, uint256 liquidityRate, uint256 underwriterRate)
        internal
        pure
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        liquidityPremium = Math.mulDiv(chargeableDebt.rayMul(liquidityRate), term, MathUtils.SECONDS_PER_YEAR);
        underwriterPremium = Math.mulDiv(chargeableDebt.rayMul(underwriterRate), term, MathUtils.SECONDS_PER_YEAR);
    }
}
