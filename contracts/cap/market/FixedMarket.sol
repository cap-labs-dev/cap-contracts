// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import { BaseMarket } from "./BaseMarket.sol";

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
        maximumTermLimit = _maximumTermLimit;
        minimumTermLimit = _minimumTermLimit;
        grace = _grace;
    }

    /// @inheritdoc IFixedMarket
    function borrow(address recipient, uint256 principal, uint256 term)
        external
        restricted
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
        returns (uint256 actualPrincipal)
    {
        if (block.timestamp >= expiry[id]) revert LoanExpired();
        uint256 term = expiry[id] - block.timestamp;
        if (term < minimumTermLimit) revert InvalidTerm();
        actualPrincipal = _borrow(id, recipient, principal, term);
    }

    /// @inheritdoc IFixedMarket
    function extend(uint256 id, uint256 extension) external restricted returns (uint256 actualExtension) {
        uint256 previousExpiry = expiry[id];
        if (block.timestamp >= previousExpiry) {
            if (extension == type(uint256).max) actualExtension = maximumTermLimit;
            else if (extension > maximumTermLimit || extension < minimumTermLimit) revert InvalidTerm();
            actualExtension = extension + block.timestamp - previousExpiry;
        } else {
            uint256 elapsed = maximumTermLimit - (previousExpiry - block.timestamp);
            if (extension == type(uint256).max) actualExtension = elapsed;
            else if (extension > elapsed) revert InvalidTerm();
        }

        _extend(id, actualExtension);
        if (healthiness() < 1e27) revert Unhealthy();
    }

    /// @inheritdoc IFixedMarket
    function extendAdmin(uint256 id, uint256 extension) external restricted returns (uint256 actualExtension) {
        uint256 previousExpiry = expiry[id];
        if (block.timestamp >= previousExpiry + grace) revert StillInGracePeriod();
        if (extension == type(uint256).max) actualExtension = maximumTermLimit;
        else if (extension > maximumTermLimit || extension < minimumTermLimit) revert InvalidTerm();
        actualExtension = extension + block.timestamp - previousExpiry;
        _extend(id, actualExtension);
    }

    /// @inheritdoc IFixedMarket
    function repay(uint256 id, uint256 amount) external returns (uint256 repaid) {
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
        returns (uint256 repaid, uint256 assetsSlashed)
    {
        (repaid, assetsSlashed) = _liquidate(recipient, _debtCheck(debt[id], amount));
        debt[id] -= repaid;
        _totalDebt -= repaid;
        emit LiquidateFixed(id, msg.sender, recipient, repaid, assetsSlashed);
    }

    /// @inheritdoc IBaseMarket
    function totalDebt() public view override(BaseMarket, IBaseMarket) returns (uint256 marketDebt) {
        marketDebt = _totalDebt;
    }

    /// @inheritdoc IFixedMarket
    function premium(uint256 chargeableDebt, uint256 term)
        external
        view
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        (uint256 liquidityRate, uint256 underwriterRate) =
            IInterestRateModel(irm()).fixedRates(address(this), term.rayDiv(maximumTermLimit));
        (liquidityPremium, underwriterPremium) = _premium(chargeableDebt, term, liquidityRate, underwriterRate);
    }

    /// @inheritdoc IFixedMarket
    function availableCredit(uint256 term) public view returns (uint256 credit) {
        credit = availableCredit();
        if (term > maximumTermLimit) term = maximumTermLimit;
        (uint256 liquidityRate, uint256 underwriterRate) =
            IInterestRateModel(irm()).fixedRates(address(this), term.rayDiv(maximumTermLimit));
        credit = credit.rayDiv(1e27 + (term.rayMul(liquidityRate)) + (term.rayMul(underwriterRate)));
    }

    /// @dev Borrow the principal
    /// @param id The id of the loan
    /// @param recipient The address to borrow to
    /// @param principal The principal of the loan
    /// @param term The term of the loan
    function _borrow(uint256 id, address recipient, uint256 principal, uint256 term)
        internal
        returns (uint256 actualPrincipal)
    {
        actualPrincipal = _creditCheck(availableCredit(term), principal);
        debt[id] += actualPrincipal;
        _totalDebt += actualPrincipal;
        _borrow(recipient, actualPrincipal);
        uint256 chargedPremium = _chargePremiumForTerm(id, actualPrincipal, term);
        emit BorrowFixed(id, recipient, term, actualPrincipal, chargedPremium);
    }

    /// @dev Extend the loan
    /// @param id The id of the loan
    /// @param extension The extension of the loan
    function _extend(uint256 id, uint256 extension) internal {
        expiry[id] += extension;
        uint256 chargedPremium = _chargePremiumForTerm(id, debt[id], extension);
        emit ExtendFixed(id, extension, chargedPremium);
    }

    /// @dev Charge the premium
    /// @param id The id of the loan
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @return chargedPremium The amount of premium that was charged
    function _chargePremiumForTerm(uint256 id, uint256 chargeableDebt, uint256 term)
        internal
        returns (uint256 chargedPremium)
    {
        (uint256 liquidityRate, uint256 underwriterRate) =
            IInterestRateModel(irm()).fixedRates(address(this), term.rayDiv(maximumTermLimit));
        (uint256 liquidityPremium, uint256 underwriterPremium) =
            _premium(chargeableDebt, term, liquidityRate, underwriterRate);
        chargedPremium = liquidityPremium + underwriterPremium;
        debt[id] += chargedPremium;
        _totalDebt += chargedPremium;
        _chargePremium(liquidityPremium, underwriterPremium);
    }

    /// @dev Fetch the premium for a loan
    /// @param chargeableDebt The amount of debt that a premium is being charged on
    /// @param term The term of the loan
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    /// @param liquidityRate The liquidity rate
    /// @param underwriterRate The underwriter rate
    function _premium(uint256 chargeableDebt, uint256 term, uint256 liquidityRate, uint256 underwriterRate)
        internal
        pure
        returns (uint256 liquidityPremium, uint256 underwriterPremium)
    {
        uint256 cumulativeDebt = chargeableDebt * term;
        liquidityPremium = cumulativeDebt.rayMul(liquidityRate);
        underwriterPremium = cumulativeDebt.rayMul(underwriterRate);
    }
}
