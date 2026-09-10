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
        if (block.timestamp >= expiry[id]) revert LoanExpired();
        uint256 term = expiry[id] - block.timestamp;
        if (term < minimumTermLimit) revert InvalidTerm();
        actualPrincipal = _borrow(id, recipient, principal, term);
    }

    /// @inheritdoc IFixedMarket
    function extend(uint256 id, uint256 extension) external restricted nonReentrant returns (uint256 actualExtension) {
        uint256 previousExpiry = expiry[id];
        if (block.timestamp >= previousExpiry) {
            actualExtension = _rollFromNow(previousExpiry, extension);
        } else {
            uint256 remaining = maximumTermLimit - (previousExpiry - block.timestamp);
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
        uint256 previousExpiry = expiry[id];
        if (block.timestamp < previousExpiry + grace) revert StillInGracePeriod();
        actualExtension = _rollFromNow(previousExpiry, extension);
        _extend(id, actualExtension);
    }

    /// @inheritdoc IFixedMarket
    function repay(uint256 id, uint256 amount) external nonReentrant returns (uint256 repaid) {
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
        (repaid, assetsSlashed) = _liquidate(recipient, _debtCheck(debt[id], amount));
        debt[id] -= repaid;
        _totalDebt -= repaid;
        emit LiquidateFixed(id, msg.sender, recipient, repaid, assetsSlashed);
    }

    /// @inheritdoc IFixedMarket
    function writeOff(uint256 id) external restricted nonReentrant returns (uint256 amount) {
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
        (liquidityPremium, underwriterPremium) = _premiumStillToMint(principal, term, principal);
    }

    /// @inheritdoc IFixedMarket
    function availableCredit(uint256 term) public view returns (uint256 credit) {
        uint256 limit = availableCredit();
        if (term > maximumTermLimit) term = maximumTermLimit;

        // the premium is charged only once this draw's own mint has moved the liquidity rate, so the
        // rate it will pay cannot be read off the market as it stands today. Price it against the
        // worst case instead: the rate that drawing the whole limit would produce. Nothing here can
        // return more than the limit, and a smaller mint can only mean a lower rate, so the premium
        // finally charged is at most the one priced in here and the debt lands inside the limit
        credit = _principalWithin(limit, term, _termRate(term, limit));
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
        actualPrincipal = _creditCheck(availableCredit(term), principal);
        debt[id] += actualPrincipal;
        _totalDebt += actualPrincipal;
        // the mint raises utilization, so the premium below is charged at a higher liquidity rate
        // than the one standing before this call. That is the intent, and availableCredit sizes
        // against it; see {IFixedMarket-availableCredit}
        _borrow(recipient, actualPrincipal);
        uint256 chargedPremium = _chargePremiumForTerm(id, actualPrincipal, term, actualPrincipal);
        // unreachable on the sizing above: it holds the debt inside the credit limit, the limit is
        // the ltv against active capital, and the threshold is the strictly larger lt against total
        // capital. That chain leans on invariants owned elsewhere though — {setLtv} and {setBuffer}
        // keeping ltv within lt, and active capital never exceeding total — so it is asserted here
        // rather than assumed. {extend} asserts the same bound after charging its own premium
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

    /// @dev The combined rate, for sizing rather than charging; see {_ratesStillToMint}
    /// @param term The term of the loan in seconds, already capped at the maximum
    /// @param mintAmount The credit-backed supply still to be minted before the charge
    /// @return rate The combined rate per year in ray decimals
    function _termRate(uint256 term, uint256 mintAmount) internal view returns (uint256 rate) {
        (uint256 liquidityRate, uint256 underwriterRate) = _ratesStillToMint(term, mintAmount);
        rate = liquidityRate + underwriterRate;
    }

    /// @dev Largest principal whose debt (principal + upfront premium) fits in `limit`.
    /// @param limit The credit that the principal and its premium together have to fit inside
    /// @param term The term of the loan in seconds
    /// @param rate The combined liquidity and underwriter rate per year in ray decimals
    /// @return principal The largest principal that fits
    function _principalWithin(uint256 limit, uint256 term, uint256 rate) internal pure returns (uint256 principal) {
        principal = Math.mulDiv(limit, 1e27, 1e27 + (term * rate) / MathUtils.SECONDS_PER_YEAR);
    }

    /// @dev Validate the term limits and store them
    /// @param _maximumTermLimit The maximum term of a loan
    /// @param _minimumTermLimit The minimum term of a loan
    function _setTermLimits(uint256 _maximumTermLimit, uint256 _minimumTermLimit) internal {
        // _borrow divides the term by the maximum, and a minimum above the maximum makes every
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
        uint256 chargedPremium = _chargePremiumForTerm(id, debt[id], extension, 0);
        emit ExtendFixed(id, extension, chargedPremium);
    }

    /// @dev Charge the premium
    /// @param id The id of the loan
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @param mintAmount The credit-backed supply minted by the call this charge belongs to
    /// @return chargedPremium The amount of premium that was charged
    function _chargePremiumForTerm(uint256 id, uint256 chargeableDebt, uint256 term, uint256 mintAmount)
        internal
        returns (uint256 chargedPremium)
    {
        // a borrow passes its own principal here even though it has already minted it, which reads
        // backwards until you look at what the rate is drawn from. Utilization is time-weighted, so
        // a mint one instruction old has stood for no time and carries no weight yet; the average
        // will not show it in this block however the charge is ordered. Handing the amount over
        // explicitly is what keeps a borrower paying for the utilization they create, rather than
        // the smoothing quietly refunding it. An extension mints nothing and passes zero.
        (uint256 liquidityPremium, uint256 underwriterPremium) = _premiumStillToMint(chargeableDebt, term, mintAmount);
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
        uint256 cumulativeDebt = chargeableDebt * term;
        liquidityPremium = cumulativeDebt.rayMul(liquidityRate) / MathUtils.SECONDS_PER_YEAR;
        underwriterPremium = cumulativeDebt.rayMul(underwriterRate) / MathUtils.SECONDS_PER_YEAR;
    }
}
