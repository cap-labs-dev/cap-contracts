// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Access } from "../access/Access.sol";
import { ILender } from "../interfaces/ILender.sol";
import { LenderStorageUtils } from "../storage/LenderStorageUtils.sol";
import { BorrowLogic } from "./libraries/BorrowLogic.sol";
import { LiquidationLogic } from "./libraries/LiquidationLogic.sol";
import { ReserveLogic } from "./libraries/ReserveLogic.sol";
import { ViewLogic } from "./libraries/ViewLogic.sol";

/// @title Lender for covered agents
/// @author kexley, Cap Labs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is ILender, UUPSUpgradeable, Access, LenderStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ILender
    function initialize(
        address _accessControl,
        address _delegation,
        address _oracle,
        uint256 _targetHealth,
        uint256 _grace,
        uint256 _expiry,
        uint256 _bonusCap,
        uint256 _emergencyLiquidationThreshold
    ) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        if (_delegation == address(0) || _oracle == address(0)) revert ZeroAddressNotValid();
        if (_targetHealth < 1e27) revert InvalidTargetHealth();
        if (_grace >= _expiry) revert GraceGreaterThanExpiry();
        if (_bonusCap > 1e27) revert InvalidBonusCap();

        LenderStorage storage $ = getLenderStorage();
        $.delegation = _delegation;
        $.oracle = _oracle;
        $.targetHealth = _targetHealth;
        $.grace = _grace;
        $.expiry = _expiry;
        $.bonusCap = _bonusCap;
        $.emergencyLiquidationThreshold = _emergencyLiquidationThreshold;
    }

    /// @inheritdoc ILender
    function borrow(address _asset, uint256 _amount, address _receiver) external returns (uint256 borrowed) {
        borrowed = BorrowLogic.borrow(
            getLenderStorage(),
            BorrowParams({
                agent: msg.sender,
                asset: _asset,
                amount: _amount,
                receiver: _receiver,
                maxBorrow: _amount == type(uint256).max
            })
        );
    }

    /// @inheritdoc ILender
    function repay(address _asset, uint256 _amount, address _agent) external returns (uint256 repaid) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        repaid = BorrowLogic.repay(
            getLenderStorage(), RepayParams({ agent: _agent, asset: _asset, amount: _amount, caller: msg.sender })
        );
    }

    /// @inheritdoc ILender
    function realizeInterest(address _asset) external returns (uint256 actualRealized) {
        actualRealized = BorrowLogic.realizeInterest(getLenderStorage(), _asset);
    }

    /// @inheritdoc ILender
    function realizeRestakerInterest(address _agent, address _asset) external returns (uint256 actualRealized) {
        actualRealized = BorrowLogic.realizeRestakerInterest(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function initiateLiquidation(address _agent) external {
        LiquidationLogic.initiateLiquidation(getLenderStorage(), _agent);
    }

    /// @inheritdoc ILender
    function cancelLiquidation(address _agent) external {
        LiquidationLogic.cancelLiquidation(getLenderStorage(), _agent);
    }

    /// @inheritdoc ILender
    function liquidate(address _agent, address _asset, uint256 _amount) external returns (uint256 liquidatedValue) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        liquidatedValue = LiquidationLogic.liquidate(
            getLenderStorage(), RepayParams({ agent: _agent, asset: _asset, amount: _amount, caller: msg.sender })
        );
    }

    /// @inheritdoc ILender
    function addAsset(AddAssetParams calldata _params) external checkAccess(this.addAsset.selector) {
        LenderStorage storage $ = getLenderStorage();
        if (!ReserveLogic.addAsset($, _params)) ++$.reservesCount;
    }

    /// @inheritdoc ILender
    function removeAsset(address _asset) external checkAccess(this.removeAsset.selector) {
        if (_asset == address(0)) revert ZeroAddressNotValid();
        ReserveLogic.removeAsset(getLenderStorage(), _asset);
    }

    /// @inheritdoc ILender
    function pauseAsset(address _asset, bool _pause) external checkAccess(this.pauseAsset.selector) {
        if (_asset == address(0)) revert ZeroAddressNotValid();
        ReserveLogic.pauseAsset(getLenderStorage(), _asset, _pause);
    }

    /// @inheritdoc ILender
    function setMinBorrow(address _asset, uint256 _minBorrow) external checkAccess(this.setMinBorrow.selector) {
        if (_asset == address(0)) revert ZeroAddressNotValid();
        ReserveLogic.setMinBorrow(getLenderStorage(), _asset, _minBorrow);
    }

    /// @inheritdoc ILender
    function setGrace(uint256 _grace) external checkAccess(this.setGrace.selector) {
        if (_grace >= getLenderStorage().expiry) revert GraceGreaterThanExpiry();
        getLenderStorage().grace = _grace;
    }

    /// @inheritdoc ILender
    function setExpiry(uint256 _expiry) external checkAccess(this.setExpiry.selector) {
        if (_expiry <= getLenderStorage().grace) revert ExpiryLessThanGrace();
        getLenderStorage().expiry = _expiry;
    }

    /// @inheritdoc ILender
    function setBonusCap(uint256 _bonusCap) external checkAccess(this.setBonusCap.selector) {
        if (_bonusCap > 1e27) revert InvalidBonusCap();
        getLenderStorage().bonusCap = _bonusCap;
    }

    /// @inheritdoc ILender
    function agent(address _agent)
        external
        view
        returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        )
    {
        (totalDelegation, totalSlashableCollateral, totalDebt, ltv, liquidationThreshold, health) =
            ViewLogic.agent(getLenderStorage(), _agent);
    }

    /// @inheritdoc ILender
    function maxBorrowable(address _agent, address _asset) external view returns (uint256 maxBorrowableAmount) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        maxBorrowableAmount = ViewLogic.maxBorrowable(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function maxLiquidatable(address _agent, address _asset) external view returns (uint256 maxLiquidatableAmount) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        maxLiquidatableAmount = ViewLogic.maxLiquidatable(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function bonus(address _agent) external view returns (uint256 maxBonus) {
        if (_agent == address(0)) revert ZeroAddressNotValid();
        maxBonus = ViewLogic.bonus(getLenderStorage(), _agent);
    }

    /// @inheritdoc ILender
    function debt(address _agent, address _asset) external view returns (uint256 totalDebt) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        totalDebt = ViewLogic.debt(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function maxRealization(address _asset) external view returns (uint256 _maxRealization) {
        _maxRealization = BorrowLogic.maxRealization(getLenderStorage(), _asset);
    }

    /// @inheritdoc ILender
    function maxRestakerRealization(address _agent, address _asset)
        external
        view
        returns (uint256 newRealizedInterest, uint256 newUnrealizedInterest)
    {
        (newRealizedInterest, newUnrealizedInterest) =
            BorrowLogic.maxRestakerRealization(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function accruedRestakerInterest(address _agent, address _asset) external view returns (uint256 accruedInterest) {
        if (_agent == address(0) || _asset == address(0)) revert ZeroAddressNotValid();
        accruedInterest = ViewLogic.accruedRestakerInterest(getLenderStorage(), _agent, _asset);
    }

    /// @inheritdoc ILender
    function reservesCount() external view returns (uint256 count) {
        count = getLenderStorage().reservesCount;
    }

    /// @inheritdoc ILender
    function grace() external view returns (uint256 gracePeriod) {
        gracePeriod = getLenderStorage().grace;
    }

    /// @inheritdoc ILender
    function expiry() external view returns (uint256 expiryPeriod) {
        expiryPeriod = getLenderStorage().expiry;
    }

    /// @inheritdoc ILender
    function targetHealth() external view returns (uint256 target) {
        target = getLenderStorage().targetHealth;
    }

    /// @inheritdoc ILender
    function bonusCap() external view returns (uint256 cap) {
        cap = getLenderStorage().bonusCap;
    }

    /// @inheritdoc ILender
    function emergencyLiquidationThreshold() external view returns (uint256 threshold) {
        threshold = getLenderStorage().emergencyLiquidationThreshold;
    }

    /// @inheritdoc ILender
    function liquidationStart(address _agent) external view returns (uint256 startTime) {
        startTime = getLenderStorage().liquidationStart[_agent];
    }

    /// @inheritdoc ILender
    function reservesData(address _asset)
        external
        view
        returns (
            uint256 id,
            address vault,
            address debtToken,
            address interestReceiver,
            uint8 decimals,
            bool paused,
            uint256 minBorrow
        )
    {
        ReserveData storage reserve = getLenderStorage().reservesData[_asset];
        id = reserve.id;
        vault = reserve.vault;
        debtToken = reserve.debtToken;
        interestReceiver = reserve.interestReceiver;
        decimals = reserve.decimals;
        paused = reserve.paused;
        minBorrow = reserve.minBorrow;
    }

    /// @inheritdoc ILender
    function unrealizedInterest(address _agent, address _asset) external view returns (uint256 _unrealizedInterest) {
        ReserveData storage reserve = getLenderStorage().reservesData[_asset];
        _unrealizedInterest = reserve.unrealizedInterest[_agent];
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
