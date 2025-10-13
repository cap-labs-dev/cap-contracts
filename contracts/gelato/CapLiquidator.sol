// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { ICapLiquidator } from "../interfaces/ICapLiquidator.sol";

import { IDelegation } from "../interfaces/IDelegation.sol";
import { ILender } from "../interfaces/ILender.sol";
import { CapLiquidatorStorageUtils } from "../storage/CapLiquidatorStorageUtils.sol";
import { IBalancerVault } from "./interfaces/IBalancerVault.sol";
import { ISwapRouter } from "./interfaces/ISwapRouter.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Cap Liquidator
/// @author kexley, Cap Labs
/// @notice Liquidates assets
contract CapLiquidator is ICapLiquidator, UUPSUpgradeable, Access, CapLiquidatorStorageUtils {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ICapLiquidator
    function initialize(
        address _accessControl,
        address _lender,
        address _delegation,
        address _balancerVault,
        address _excessReceiver,
        address _router
    ) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        CapLiquidatorStorage storage s = getCapLiquidatorStorage();
        s.lender = _lender;
        s.delegation = _delegation;
        s.balancerVault = _balancerVault;
        s.excessReceiver = _excessReceiver;
        s.router = _router;
    }

    /// @inheritdoc ICapLiquidator
    function liquidate(address _agent, address _asset, uint256 _amount) external {
        CapLiquidatorStorage storage $ = getCapLiquidatorStorage();

        // Can only borrow up to the balance of the balancer vault
        uint256 maxBorrowable = IERC20(_asset).balanceOf($.balancerVault);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = _asset;
        amounts[0] = _amount > maxBorrowable ? maxBorrowable : _amount;

        // Set flashInProgress to true to prevent other contracts from initiating a flashloan to this contract
        $.flashInProgress = true;

        // Flashloan the asset
        IBalancerVault($.balancerVault).flashLoan(address(this), assets, amounts, abi.encode(_agent));
    }

    /// @inheritdoc ICapLiquidator
    function receiveFlashLoan(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        CapLiquidatorStorage storage $ = getCapLiquidatorStorage();
        if (msg.sender != $.balancerVault || !$.flashInProgress) revert InvalidFlashLoan();

        address asset = assets[0];
        address agent = abi.decode(userData, (address));
        address collateral = IDelegation($.delegation).collateralAddress(agent);
        if (collateral == address(0)) revert InvalidCollateral();

        // Liquidate the asset
        _checkApproval(asset, $.lender, amounts[0]);
        ILender($.lender).liquidate(agent, asset, amounts[0], 0);

        // Swap collateral to asset
        uint256 repayAmount = amounts[0] + feeAmounts[0];
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        // Make sure we don't underflow if there is already some asset in the contract
        if (repayAmount > assetBalance) {
            uint256 swapAmountTo = repayAmount - assetBalance;
            uint256 collateralBalance = IERC20(collateral).balanceOf(address(this));
            _checkApproval(collateral, $.router, collateralBalance);
            ISwapRouter($.router).swapExactOut(collateral, asset, swapAmountTo);
        }

        // Repay the flashloan
        IERC20(asset).safeTransfer($.balancerVault, repayAmount);

        // Send excess asset and collateral to the excess receiver
        uint256 excessAmount = IERC20(asset).balanceOf(address(this));
        if (excessAmount > 0) IERC20(asset).safeTransfer($.excessReceiver, excessAmount);

        excessAmount = IERC20(collateral).balanceOf(address(this));
        if (excessAmount > 0) IERC20(collateral).safeTransfer($.excessReceiver, excessAmount);

        // Unlock the flashloan lock
        $.flashInProgress = false;

        emit Liquidated(agent, asset, collateral, excessAmount);
    }

    /// @inheritdoc ICapLiquidator
    function setExcessReceiver(address _excessReceiver) external checkAccess(this.setExcessReceiver.selector) {
        CapLiquidatorStorage storage $ = getCapLiquidatorStorage();
        $.excessReceiver = _excessReceiver;

        emit ExcessReceiverSet(_excessReceiver);
    }

    /// @inheritdoc ICapLiquidator
    function checker(address _agent, address _asset) external view returns (bool canExec, bytes memory execPayload) {
        CapLiquidatorStorage storage $ = getCapLiquidatorStorage();

        uint256 maxLiquidatable = ILender($.lender).maxLiquidatable(_agent, _asset);

        if (maxLiquidatable > 0) {
            uint256 liquidationStart = ILender($.lender).liquidationStart(_agent);
            if (
                block.timestamp > liquidationStart + ILender($.lender).grace()
                    && block.timestamp < liquidationStart + ILender($.lender).expiry()
            ) {
                return (true, abi.encodeCall(this.liquidate, (_agent, _asset, maxLiquidatable)));
            } else {
                return (false, bytes("Liquidation window not open"));
            }
        } else {
            return (false, bytes("No liquidatable amount"));
        }
    }

    /// @dev Check approval and increase allowance if needed
    /// @param _asset Asset address
    /// @param _spender Spender address
    /// @param _amount Amount to approve
    function _checkApproval(address _asset, address _spender, uint256 _amount) private {
        uint256 allowance = IERC20(_asset).allowance(address(this), _spender);
        if (allowance < _amount) {
            IERC20(_asset).forceApprove(_spender, _amount);
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
