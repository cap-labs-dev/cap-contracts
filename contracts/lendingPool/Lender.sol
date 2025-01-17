// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";
import { BorrowLogic } from "./libraries/BorrowLogic.sol";
import { LiquidationLogic } from "./libraries/LiquidationLogic.sol";
import { ReserveLogic } from "./libraries/ReserveLogic.sol";
import { ViewLogic } from "./libraries/ViewLogic.sol";
import { Errors } from "./libraries/helpers/Errors.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";
import { LenderStorage } from "./libraries/LenderStorage.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is UUPSUpgradeable, AccessUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the lender
    /// @param _accessControl Access control address
    /// @param _delegation Delegation address
    /// @param _oracle Oracle address
    /// @param _targetHealth Target health after liquidations
    /// @param _grace Grace period before an agent becomes liquidatable
    /// @param _expiry Expiry period after which an agent cannot be liquidated until called again
    function initialize(
        address _accessControl,
        address _delegation,
        address _oracle,
        uint256 _targetHealth,
        uint256 _grace,
        uint256 _expiry,
        uint256 _bonusCap
    ) external initializer {
        __Access_init(_accessControl);

        // TODO: remove this
        DataTypes.LenderStorage storage $ = LenderStorage.get();
        $.delegation = _delegation;
        $.oracle = _oracle;
        $.targetHealth = _targetHealth;
        $.grace = _grace;
        $.expiry = _expiry;
        $.bonusCap = _bonusCap;
    }

    /// @notice Borrow an asset
    /// @param _asset Asset to borrow
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    function borrow(address _asset, uint256 _amount, address _receiver) external {
        BorrowLogic.borrow(
            LenderStorage.get(),
            DataTypes.BorrowParams({
                agent: msg.sender,
                asset: _asset,
                amount: _amount,
                receiver: _receiver
            })
        );
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount to repay
    /// @param _agent Repay on behalf of another borrower
    /// @return repaid Actual amount repaid
    function repay(address _asset, uint256 _amount, address _agent)
        external
        returns (uint256 repaid)
    {
        repaid = BorrowLogic.repay(
            LenderStorage.get(),
            DataTypes.RepayParams({
                agent: _agent,
                asset: _asset,
                amount: _amount,
                caller: msg.sender
            })
        );
    }

    /// @notice Realize interest for an asset
    /// @param _asset Asset to realize interest for
    /// @param _amount Amount of interest to realize (type(uint).max for all available interest)
    /// @return actualRealized Actual amount realized
    function realizeInterest(address _asset, uint256 _amount) external returns (uint256 actualRealized) {
        actualRealized = BorrowLogic.realizeInterest(
            LenderStorage.get(),
            DataTypes.RealizeInterestParams({
                asset: _asset,
                amount: _amount
            })
        );
    }

    /// @notice Initiate liquidation of an agent when the health is below 1
    /// @param _agent Agent address
    function initiateLiquidation(address _agent) external {
        LiquidationLogic.initiateLiquidation(LenderStorage.get(), _agent);
    }

    /// @notice Cancel liquidation of an agent when the health is above 1
    /// @param _agent Agent address
    function cancelLiquidation(address _agent) external {
        LiquidationLogic.cancelLiquidation(LenderStorage.get(), _agent);
    }

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay on behalf of the agent
    /// @param liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(address _agent, address _asset, uint256 _amount) external returns (uint256 liquidatedValue) {
        liquidatedValue = LiquidationLogic.liquidate(
            LenderStorage.get(),
            DataTypes.RepayParams({
                agent: _agent,
                asset: _asset,
                amount: _amount,
                caller: msg.sender
            })
        );
    }

    /// @notice Calculate the agent data
    /// @param _agent Address of agent
    /// @return totalDelegation Total delegation of an agent
    /// @return totalDebt Total debt of an agent
    /// @return ltv Loan to value ratio
    /// @return liquidationThreshold Liquidation ratio of an agent
    /// @return health Health status of an agent
    function agent(address _agent)
        external
        view
        returns (uint256 totalDelegation, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health)
    {
        (totalDelegation, totalDebt, ltv, liquidationThreshold, health) 
            = ViewLogic.agent(LenderStorage.get(), _agent);
    }

    /// @notice Add an asset to the Lender
    /// @param _params Parameters to add an asset
    function addAsset(DataTypes.AddAssetParams calldata _params) external checkAccess(this.addAsset.selector) {
        DataTypes.LenderStorage storage $ = LenderStorage.get();
        if (ReserveLogic.addAsset($, _params)) ++$.reservesCount;
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(address _asset) external checkAccess(this.removeAsset.selector) {
        ReserveLogic.removeAsset(LenderStorage.get(), _asset);
    }

    /// @notice Pause an asset from being borrowed
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(address _asset, bool _pause) external checkAccess(this.pauseAsset.selector) {
        ReserveLogic.pauseAsset(LenderStorage.get(), _asset, _pause);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
