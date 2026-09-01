// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { IStablecoin } from "../../interfaces/IStablecoin.sol";
import { ITranche } from "../../interfaces/ITranche.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseMarket
/// @author kexley, Cap Labs
/// @notice Shared base contract for fixed and floating markets
abstract contract BaseMarket is IBaseMarket, AccessManagedUpgradeable {
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

        IRegistry registry = IRegistry(_registry);
        $.irm = registry.irm();
        $.stablecoin = registry.stablecoin();
        $.stakedStablecoin = registry.stakedStablecoin();
        $.lt = registry.lt();
        $.buffer = registry.buffer();
        $.targetHealth = registry.targetHealth();
    }

    /// @inheritdoc IBaseMarket
    function setLtv(uint256 _ltv) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_ltv + $.buffer > $.lt) revert InvalidLtv();
        $.ltv = _ltv;
        emit SetLtv(_ltv);
    }

    /// @inheritdoc IBaseMarket
    function setBuffer(uint256 _buffer) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_buffer > 1e27) revert InvalidBuffer();
        $.buffer = _buffer;
        emit SetBuffer(_buffer);
    }

    /// @inheritdoc IBaseMarket
    function setLt(uint256 _lt) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_lt > 1e27) revert InvalidLt();
        $.lt = _lt;
        emit SetLt(_lt);
    }

    /// @inheritdoc IBaseMarket
    function setFixedCreditLimit(uint256 _fixedCreditLimit) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        $.fixedCreditLimit = _fixedCreditLimit;
        emit SetFixedCreditLimit(_fixedCreditLimit);
    }

    /// @inheritdoc IBaseMarket
    function setTargetHealth(uint256 _targetHealth) external restricted {
        if (_targetHealth < 1e27) revert InvalidTargetHealth();
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        $.targetHealth = _targetHealth;
        emit SetTargetHealth(_targetHealth);
    }

    /// @inheritdoc IBaseMarket
    function setStakedStablecoin(address _stakedStablecoin) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        $.stakedStablecoin = _stakedStablecoin;
        emit SetStakedStablecoin(_stakedStablecoin);
    }

    /// @inheritdoc IBaseMarket
    function setTranches(Tranche[] calldata _tranches) external restricted {
        _setTranches(_tranches);
    }

    /// @inheritdoc IBaseMarket
    function setTrancheWeights(uint256[] calldata _weights) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (_weights.length != $.tranches.length) revert InvalidMarket();
        Tranche[] memory updatedTranches = new Tranche[]($.tranches.length);
        for (uint256 i; i < $.tranches.length; ++i) {
            updatedTranches[i] = Tranche({ tranche: $.tranches[i].tranche, weight: _weights[i] });
        }
        _setTranches(updatedTranches);
    }

    /// @inheritdoc IBaseMarket
    function setUnderwriterRate(uint256 rate) external restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IInterestRateModel($.irm).setUnderwriterRate(rate);
        emit SetUnderwriterRate(rate);
    }

    /// @inheritdoc IBaseMarket
    function setMarketMultiplier(uint256 multiplier) external virtual restricted {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IInterestRateModel($.irm).setMarketMultiplier(multiplier);
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
    function stakedStablecoin() public view returns (address stakedStablecoinAddress) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        stakedStablecoinAddress = $.stakedStablecoin;
    }

    /// @inheritdoc IBaseMarket
    function irm() public view returns (address irmAddress) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        irmAddress = $.irm;
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
    function maxLiquidatable() public view returns (uint256 liquidatable) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        uint256 liquidationThreshold = debtLiquidationThreshold();
        uint256 debt = totalDebt();
        if (debt > liquidationThreshold) {
            liquidatable = (($.targetHealth.rayMul(debt) - liquidationThreshold).rayDiv($.targetHealth - $.lt));
            if (liquidatable > debt) liquidatable = debt;
        }
    }

    /// @inheritdoc IBaseMarket
    function lockedAssets(address tranche) public view returns (uint256 assets) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        assets = totalDebt().rayDiv($.lt - $.buffer);

        for (uint256 i = $.tranches.length; i > 0;) {
            i--;
            if ($.tranches[i].tranche == tranche) break;
            uint256 capital = ITranche($.tranches[i].tranche).totalCapital();
            if (capital > assets) {
                assets = 0;
                break;
            }
            assets -= capital;
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
    function variableCreditLimit() public view returns (uint256 limit) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        for (uint256 i; i < $.tranches.length; ++i) {
            limit += ITranche($.tranches[i].tranche).activeCapital();
        }
        limit = limit.rayMul($.ltv);
    }

    /// @dev Mint credit-backed stablecoin to the recipient
    function _borrow(address recipient, uint256 principal) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IStablecoin($.stablecoin).mintCreditBacked(recipient, principal);
        emit Borrow(recipient, principal);
    }

    /// @dev Burn credit-backed stablecoin from the caller
    function _repay(uint256 amount) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        IStablecoin($.stablecoin).burnCreditBacked(msg.sender, amount);
        emit Repay(msg.sender, amount);
    }

    /// @dev Repay debt and slash tranche collateral when the market is unhealthy
    function _liquidate(address recipient, uint256 amount) internal returns (uint256 repaid, uint256 slashed) {
        BaseMarketStorage storage $ = _getBaseMarketStorage();
        if (healthiness() >= 1e27) revert Healthy();

        repaid = Math.min(amount, maxLiquidatable());
        if (repaid == 0) return (0, 0);

        _repay(repaid);

        uint256 toSlash = repaid.rayMul(1e27 + IInterestRateModel($.irm).liquidationBonus());

        for (uint256 i = $.tranches.length; i > 0;) {
            i--;
            uint256 slashedAmount = ITranche($.tranches[i].tranche).slash(toSlash, recipient);
            slashed += slashedAmount;
            toSlash -= slashedAmount;
            if (toSlash == 0) break;
        }

        emit Liquidate(msg.sender, recipient, repaid, slashed);
    }

    /// @dev Set the tranches and weights
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
    function _creditCheck(uint256 credit, uint256 principal) internal pure returns (uint256 actualPrincipal) {
        if (principal == type(uint256).max) actualPrincipal = credit;
        else if (principal > credit) revert InsufficientLiquidity();
        else actualPrincipal = principal;
        if (actualPrincipal == 0) revert InvalidPrincipal();
    }

    /// @dev Check debt before a repayment
    function _debtCheck(uint256 debt, uint256 repayAmount) internal pure returns (uint256 actualToRepay) {
        if (repayAmount == type(uint256).max) actualToRepay = debt;
        else actualToRepay = Math.min(debt, repayAmount);
        if (actualToRepay == 0) revert InvalidAmount();
    }

    /// @dev Charge the premium
    /// @param liquidityPremium The amount of liquidity premium to charge
    /// @param underwriterPremium The amount of underwriter premium to charge
    function _chargePremium(uint256 liquidityPremium, uint256 underwriterPremium) internal {
        BaseMarketStorage storage $ = _getBaseMarketStorage();

        if (liquidityPremium > 0) {
            IStablecoin($.stablecoin).mintCreditBacked($.stakedStablecoin, liquidityPremium);
            emit ChargePremium($.stakedStablecoin, liquidityPremium);
        }

        for (uint256 i; i < $.tranches.length; ++i) {
            address tranche = $.tranches[i].tranche;
            if (ITranche(tranche).activeSupply() == 0) continue;
            uint256 premium = underwriterPremium.rayMul($.tranches[i].weight);
            IStablecoin($.stablecoin).mintCreditBacked(tranche, premium);
            ITranche(tranche).notifyPremium();
            emit ChargePremium(tranche, premium);
        }
    }
}
