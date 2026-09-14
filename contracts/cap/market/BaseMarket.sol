// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { IPremiumVesting } from "../../interfaces/IPremiumVesting.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { IStablecoin } from "../../interfaces/IStablecoin.sol";
import { ITranche } from "../../interfaces/ITranche.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseMarket
/// @author kexley, Cap Labs
/// @notice Shared base contract for fixed and floating markets
/// @dev Beacon instances. Upgrade via {UpgradeableBeacon-upgradeTo} on the market beacon.
abstract contract BaseMarket is IBaseMarket, AccessManagedUpgradeable, ReentrancyGuardTransient {
    using WadRayMath for uint256;

    // keccak256(abi.encode(uint256(keccak256("cap.storage.BaseMarket")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev ERC-7201 storage slot for BaseMarket
    bytes32 private constant BASE_MARKET_STORAGE_LOCATION =
        0x3084c044a22fd484d804b5e5eef3193432b474e4843f6459770a418b6e662700;

    /// @dev Get the ERC-7201 namespaced storage pointer
    /// @return $ The BaseMarket storage struct
    function _getBaseMarketStorage() private pure returns (BaseMarketStorage storage $) {
        assembly {
            $.slot := BASE_MARKET_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initialize shared market storage from the registry
    /// @param _authority The access manager address
    /// @param _registry The registry providing shared market configuration
    /// @param _name The market name
    // forge-lint: disable-next-item(mixed-case-function)
    function __BaseMarket_init(address _authority, address _registry, string memory _name) internal onlyInitializing {
        __AccessManaged_init(_authority);
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        $.name = _name;
        $.registry = _registry;

        $.irm = IRegistry(_registry).irm();
        $.stablecoin = IRegistry(_registry).stablecoin();
        $.lt = IRegistry(_registry).lt();
        $.buffer = IRegistry(_registry).buffer();
        $.targetHealth = IRegistry(_registry).targetHealth();
    }

    /// @inheritdoc IBaseMarket
    function setDepositorRole(uint64 roleId) external restricted nonReentrant {
        IRegistry(_getBaseMarketStorage().registry).setDepositorRole(roleId);
    }

    /// @inheritdoc IBaseMarket
    function setBorrowerRole(uint64 roleId) external restricted nonReentrant {
        IRegistry(_getBaseMarketStorage().registry).setBorrowerRole(roleId);
    }

    /// @inheritdoc IBaseMarket
    function setLtv(uint256 _ltv) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_ltv + $.buffer > $.lt) revert InvalidLtv();
        $.ltv = _ltv;
        emit SetLtv(_ltv);
    }

    /// @inheritdoc IBaseMarket
    function setBuffer(uint256 _buffer) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        // must stay below lt (lockedValue divides by lt - buffer). Raising the buffer only
        // tightens, so ltv is not re-checked.
        if (_buffer >= $.lt) revert InvalidBuffer();
        $.buffer = _buffer;
        emit SetBuffer(_buffer);
    }

    /// @inheritdoc IBaseMarket
    function setLt(uint256 _lt) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_lt > 1e27) revert InvalidLt();
        // must stay above the buffer. Dropping below ltv is allowed (forces unhealthy).
        if (_lt <= $.buffer) revert InvalidLt();
        $.lt = _lt;
        emit SetLt(_lt);
    }

    /// @inheritdoc IBaseMarket
    function setFixedCreditLimit(uint256 _fixedCreditLimit) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        $.fixedCreditLimit = _fixedCreditLimit;
        emit SetFixedCreditLimit(_fixedCreditLimit);
    }

    /// @inheritdoc IBaseMarket
    function setTargetHealth(uint256 _targetHealth) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_targetHealth < 1.25e27) revert InvalidTargetHealth();
        $.targetHealth = _targetHealth;
        emit SetTargetHealth(_targetHealth);
    }

    /// @inheritdoc IBaseMarket
    function setTranches(Tranche[] calldata _tranches) external restricted nonReentrant {
        _setTranches(_tranches);
    }

    /// @inheritdoc IBaseMarket
    function setTrancheWeights(uint256[] calldata _weights) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_weights.length != $.tranches.length) revert InvalidMarket();
        Tranche[] memory updatedTranches = new Tranche[]($.tranches.length);
        for (uint256 i; i < $.tranches.length; ++i) {
            updatedTranches[i] = Tranche({ tranche: $.tranches[i].tranche, weight: _weights[i] });
        }
        _setTranches(updatedTranches);
    }

    /// @inheritdoc IBaseMarket
    function setUnderwriterRate(uint256 rate) external restricted nonReentrant {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IInterestRateModel($.irm).updateUnderwriterRate(rate);
        emit SetUnderwriterRate(rate);
    }

    /// @inheritdoc IBaseMarket
    function setMarketMultiplier(uint256 multiplier) external virtual restricted nonReentrant {
        _setMarketMultiplier(multiplier);
    }

    /// @dev Store a multiplier inside the IRM band. Floating overrides {setMarketMultiplier} to
    /// accrue first so the new factor applies only to subsequent growth.
    /// @param multiplier The new market multiplier in ray decimals
    function _setMarketMultiplier(uint256 multiplier) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IInterestRateModel irm_ = IInterestRateModel($.irm);
        if (multiplier < irm_.minimumMarketMultiplier() || multiplier > irm_.maximumMarketMultiplier()) {
            revert IInterestRateModel.InvalidMultiplier();
        }
        $.marketMultiplier = multiplier;
        emit SetMarketMultiplier(multiplier);
    }

    /// @inheritdoc IBaseMarket
    function name() public view returns (string memory nameString) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        nameString = $.name;
    }

    /// @inheritdoc IBaseMarket
    function stablecoin() public view returns (address stablecoinAddress) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        stablecoinAddress = $.stablecoin;
    }

    /// @inheritdoc IBaseMarket
    function irm() public view returns (address irmAddress) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        irmAddress = $.irm;
    }

    /// @inheritdoc IBaseMarket
    function registry() public view returns (address registryAddress) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        registryAddress = $.registry;
    }

    /// @inheritdoc IBaseMarket
    function lt() public view returns (uint256 ltValue) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        ltValue = $.lt;
    }

    /// @inheritdoc IBaseMarket
    function buffer() public view returns (uint256 bufferValue) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        bufferValue = $.buffer;
    }

    /// @inheritdoc IBaseMarket
    function targetHealth() public view returns (uint256 targetHealthValue) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        targetHealthValue = $.targetHealth;
    }

    /// @inheritdoc IBaseMarket
    function ltv() public view returns (uint256 ltvValue) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        ltvValue = $.ltv;
    }

    /// @inheritdoc IBaseMarket
    function marketMultiplier() public view returns (uint256 multiplier) {
        multiplier = _getBaseMarketStorage().marketMultiplier;
        if (multiplier == 0) multiplier = 1e27;
    }

    /// @inheritdoc IBaseMarket
    function fixedCreditLimit() public view returns (uint256 fixedCreditLimitValue) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        fixedCreditLimitValue = $.fixedCreditLimit;
    }

    /// @inheritdoc IBaseMarket
    function tranches() public view returns (Tranche[] memory) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        return $.tranches;
    }

    /// @inheritdoc IBaseMarket
    function totalDebt() public view virtual returns (uint256) { }

    /// @inheritdoc IBaseMarket
    function debtLiquidationThreshold() public view returns (uint256) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        return totalCapital().rayMul($.lt);
    }

    /// @inheritdoc IBaseMarket
    function healthiness() public view returns (uint256) {
        uint256 debt = totalDebt();
        if (debt == 0) return 1e27;
        return debtLiquidationThreshold().rayDiv(debt);
    }

    /// @inheritdoc IBaseMarket
    function utilization() public view returns (uint256) {
        uint256 credit = creditLimit();
        if (credit == 0) return 0;
        return totalDebt().rayDiv(credit);
    }

    /// @inheritdoc IBaseMarket
    /// @dev Repayment that lands health on {targetHealth}, capped at {recoverableDebt}.
    function maxLiquidatable() public view returns (uint256 liquidatable) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        uint256 liquidationThreshold = debtLiquidationThreshold();
        uint256 debt = totalDebt();
        if (debt > liquidationThreshold) {
            uint256 perCleared = $.targetHealth - _slashPerDebt().rayMul($.lt);
            liquidatable = ($.targetHealth.rayMul(debt) - liquidationThreshold).rayDiv(perCleared);
            uint256 cap = Math.min(debt, recoverableDebt());
            if (liquidatable > cap) liquidatable = cap;
        }
    }

    /// @inheritdoc IBaseMarket
    function recoverableDebt() public view returns (uint256 recoverable) {
        recoverable = totalCapital().rayDiv(_slashPerDebt());
    }

    /// @inheritdoc IBaseMarket
    function unrecoverableDebt() public view returns (uint256 unrecoverable) {
        uint256 debt = totalDebt();
        uint256 recoverable = recoverableDebt();
        if (debt > recoverable) unrecoverable = debt - recoverable;
    }

    /// @inheritdoc IBaseMarket
    function lockedValue(address tranche) public view returns (uint256 value) {
        uint256 debt = totalDebt();
        // nothing to lock, and walking the stack would price every junior for no reason
        if (debt == 0) return 0;

        BaseMarketStorage storage $ = _getBaseMarketStorage();
        // ceil so a later token conversion cannot start from an understated USD requirement
        value = Math.mulDiv(debt, WadRayMath.RAY, $.lt - $.buffer, Math.Rounding.Ceil);

        for (uint256 i = $.tranches.length; i > 0;) {
            i--;
            if ($.tranches[i].tranche == tranche) break;
            uint256 capital = ITranche($.tranches[i].tranche).totalCapital();
            if (capital > value) {
                value = 0;
                break;
            }
            value -= capital;
        }
    }

    /// @inheritdoc IBaseMarket
    function totalCapital() public view returns (uint256 capital) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        for (uint256 i; i < $.tranches.length; ++i) {
            capital += ITranche($.tranches[i].tranche).totalCapital();
        }
    }

    /// @inheritdoc IBaseMarket
    function availableCredit() public view virtual returns (uint256 credit) {
        uint256 debt = totalDebt();
        uint256 limit = creditLimit();
        credit = debt < limit ? limit - debt : 0;
    }

    /// @inheritdoc IBaseMarket
    function creditLimit() public view returns (uint256 limit) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        limit = Math.min($.fixedCreditLimit, variableCreditLimit());
    }

    /// @inheritdoc IBaseMarket
    /// @dev `activeCapital * min(ltv, lt)`. Guardian tightening of `lt` below `ltv` cuts new
    /// credit immediately; existing debt can still sit unhealthy.
    function variableCreditLimit() public view returns (uint256 limit) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        uint256 _limit;
        for (uint256 i; i < $.tranches.length; ++i) {
            _limit += ITranche($.tranches[i].tranche).activeCapital();
        }
        limit = _limit.rayMul(Math.min($.ltv, $.lt));
    }

    /// @dev Mint credit-backed stablecoin to the recipient
    /// @param recipient The account receiving the minted principal
    /// @param principal The amount of credit-backed stablecoin to mint
    function _borrow(address recipient, uint256 principal) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IStablecoin($.stablecoin).mintCreditBacked(recipient, principal);
        emit Borrow(recipient, principal);
    }

    /// @dev Burn credit-backed stablecoin from the caller
    /// @param amount The amount of credit-backed stablecoin to burn
    function _repay(uint256 amount) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IStablecoin($.stablecoin).burnCreditBacked(msg.sender, amount);
        emit Repay(msg.sender, amount);
    }

    /// @dev Collateral released per unit of debt repaid: `1 + liquidationBonus`, at par.
    /// @return perDebt The collateral value released per unit of debt, in ray decimals
    function _slashPerDebt() internal view returns (uint256 perDebt) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        perDebt = 1e27 + IInterestRateModel($.irm).liquidationBonus();
    }

    /// @dev Repay debt and slash tranche collateral when the market is unhealthy
    /// @param recipient The account receiving slashed collateral
    /// @param amount The debt the caller is offering to repay
    /// @return repaid The debt actually repaid
    /// @return slashed The collateral value slashed, in USD (18 decimals)
    function _liquidate(address recipient, uint256 amount) internal returns (uint256 repaid, uint256 slashed) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (healthiness() >= 1e27) revert Healthy();

        repaid = Math.min(amount, maxLiquidatable());
        if (repaid == 0) return (0, 0);

        _repay(repaid);

        uint256 toSlash = repaid.rayMul(_slashPerDebt());

        // Each slash reports only the value it delivered. Remainder — empty junior,
        // or a request below that tranche's token unit — is offered to the next.
        // Dust left after the senior is uncollected; repayment already settled.
        for (uint256 i = $.tranches.length; i > 0;) {
            i--;
            uint256 slashedAmount = ITranche($.tranches[i].tranche).slash(toSlash, recipient);
            slashed += slashedAmount;
            toSlash -= slashedAmount;
            if (toSlash == 0) break;
        }

        emit Liquidate(msg.sender, recipient, repaid, slashed);
    }

    /// @dev Record the shortfall as bad debt. Bounded by {unrecoverableDebt}.
    /// @param amount The amount of debt to write off
    function _writeOff(uint256 amount) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (amount == 0) revert InvalidAmount();
        if (amount > unrecoverableDebt()) revert ExceedsUnrecoverableDebt();
        IStablecoin($.stablecoin).recognizeBadDebtInCredit(amount);
        emit WriteOff(msg.sender, amount);
    }

    /// @dev Set the tranches and weights
    /// @param _tranches The tranches and their weights, index 0 is most senior
    function _setTranches(Tranche[] memory _tranches) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        delete $.tranches;
        uint256 totalWeight;
        for (uint256 i; i < _tranches.length; ++i) {
            if (_tranches[i].tranche == address(0)) revert ZeroAddress();
            if (ITranche(_tranches[i].tranche).market() != address(this)) revert InvalidMarket();
            for (uint256 j; j < i; ++j) {
                if (_tranches[j].tranche == _tranches[i].tranche) revert TrancheAlreadySet();
            }
            $.tranches.push(_tranches[i]);
            totalWeight += _tranches[i].weight;
            emit SetTranche(_tranches[i].tranche, _tranches[i].weight, i);
        }
        if (totalWeight != 1e27) revert InvalidTrancheWeightsTotal();
        if (healthiness() < 1e27) revert Unhealthy();
    }

    /// @dev Check available credit before a borrow
    /// @param credit The credit available
    /// @param principal The principal requested, or `type(uint256).max` for the full credit
    /// @return actualPrincipal The principal that will be drawn
    function _creditCheck(uint256 credit, uint256 principal) internal pure returns (uint256 actualPrincipal) {
        if (principal == type(uint256).max) actualPrincipal = credit;
        else if (principal > credit) revert InsufficientLiquidity();
        else actualPrincipal = principal;
        if (actualPrincipal == 0) revert InvalidPrincipal();
    }

    /// @dev Check debt before a repayment
    /// @param debt The outstanding debt
    /// @param repayAmount The amount offered, or `type(uint256).max` for the full debt
    /// @return actualToRepay The amount that will be repaid
    function _debtCheck(uint256 debt, uint256 repayAmount) internal pure returns (uint256 actualToRepay) {
        if (repayAmount == type(uint256).max) actualToRepay = debt;
        else actualToRepay = Math.min(debt, repayAmount);
        if (actualToRepay == 0) revert InvalidAmount();
    }

    /// @dev Charge the premium
    /// @dev Tranches that still hold capital and have opted-in shares take their weight of the
    /// underwriter premium. Dust and ineligible-tranche weight go to the senior tranche, or vest
    /// on the stablecoin. Already-funded premium is not touched.
    /// @param liquidityPremium The amount of liquidity premium to charge
    /// @param underwriterPremium The amount of underwriter premium to charge
    function _chargePremium(uint256 liquidityPremium, uint256 underwriterPremium) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();

        if (liquidityPremium > 0) {
            IStablecoin($.stablecoin).fundCreditBacked(liquidityPremium);
            emit ChargePremium($.stablecoin, liquidityPremium);
        }

        if (underwriterPremium == 0) return;

        uint256 remaining = underwriterPremium;
        bool seniorActive;
        uint256 length = $.tranches.length;
        for (uint256 i; i < length; ++i) {
            address tranche = $.tranches[i].tranche;
            if (!_earnsPremium(tranche)) continue;
            if (i == 0) {
                seniorActive = true;
                continue;
            }
            uint256 premium = underwriterPremium.rayMul($.tranches[i].weight);
            if (premium > remaining) premium = remaining;
            if (premium == 0) continue;
            remaining -= premium;
            IStablecoin($.stablecoin).mintCreditBacked(tranche, premium);
            ITranche(tranche).fund(premium);
            emit ChargePremium(tranche, premium);
        }

        if (remaining == 0) return;

        if (seniorActive) {
            address senior = $.tranches[0].tranche;
            IStablecoin($.stablecoin).mintCreditBacked(senior, remaining);
            ITranche(senior).fund(remaining);
            emit ChargePremium(senior, remaining);
        } else {
            IStablecoin($.stablecoin).fundCreditBacked(remaining);
            emit ChargePremium($.stablecoin, remaining);
        }
    }

    /// @dev New underwriting premium is for capital that still backs the market and can be claimed.
    /// Shares survive a wipeout, so {IPremiumVesting-stakedSupply} alone would keep paying a
    /// depleted tranche.
    /// @param tranche The tranche being considered
    /// @return eligible Whether the tranche should receive a fresh allocation
    function _earnsPremium(address tranche) private view returns (bool eligible) {
        if (IPremiumVesting(tranche).stakedSupply() == 0) return false;
        eligible = ITranche(tranche).totalCapital() > 0;
    }
}
