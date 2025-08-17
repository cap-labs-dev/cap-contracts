// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";

import { IStakedCap } from "../interfaces/IStakedCap.sol";
import { FeeReceiverStorageUtils } from "../storage/FeeReceiverStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Fee Receiver
/// @author weso, Cap Labs
/// @notice Fee receiver contract
contract FeeReceiver is IFeeReceiver, UUPSUpgradeable, Access, FeeReceiverStorageUtils {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFeeReceiver
    function initialize(address _accessControl, address _capToken, address _stakedCapToken) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        if (address(_capToken) == address(0) || address(_stakedCapToken) == address(0)) revert ZeroAddressNotValid();

        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        $.capToken = IERC20(_capToken);
        $.stakedCapToken = IStakedCap(_stakedCapToken);
    }

    /// @inheritdoc IFeeReceiver
    function distribute() external {
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        if ($.capToken.balanceOf(address(this)) > 0) {
            if ($.protocolFeePercentage > 0) _claimProtocolFees();
            uint256 bal = $.capToken.balanceOf(address(this));
            $.capToken.safeTransfer(address($.stakedCapToken), bal);
            emit FeesDistributed(bal);
        }

        if ($.stakedCapToken.lastNotify() + $.stakedCapToken.lockDuration() < block.timestamp) {
            $.stakedCapToken.notify();
        }
    }

    /// @inheritdoc IFeeReceiver
    function setCapToken(address _capToken) external checkAccess(this.setCapToken.selector) {
        if (_capToken == address(0)) revert ZeroAddressNotValid();
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        $.capToken = IERC20(_capToken);
        emit CapTokenSet(_capToken);
    }

    /// @inheritdoc IFeeReceiver
    function setStakedCapToken(address _stakedCapToken) external checkAccess(this.setStakedCapToken.selector) {
        if (_stakedCapToken == address(0)) revert ZeroAddressNotValid();
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        $.stakedCapToken = IStakedCap(_stakedCapToken);
        emit StakedCapTokenSet(_stakedCapToken);
    }

    /// @inheritdoc IFeeReceiver
    function setProtocolFeePercentage(uint256 _protocolFeePercentage)
        external
        checkAccess(this.setProtocolFeePercentage.selector)
    {
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        if (_protocolFeePercentage > 1e27) revert InvalidProtocolFeePercentage();
        if ($.protocolFeeReceiver == address(0)) revert NoProtocolFeeReceiverSet();
        $.protocolFeePercentage = _protocolFeePercentage;
        emit ProtocolFeePercentageSet(_protocolFeePercentage);
    }

    /// @inheritdoc IFeeReceiver
    function setProtocolFeeReceiver(address _protocolFeeReceiver)
        external
        checkAccess(this.setProtocolFeeReceiver.selector)
    {
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        if (_protocolFeeReceiver == address(0)) revert ZeroAddressNotValid();
        $.protocolFeeReceiver = _protocolFeeReceiver;
        emit ProtocolFeeReceiverSet(_protocolFeeReceiver);
    }

    /// @dev Transfers the protocol fee to the protocol fee receiver
    function _claimProtocolFees() private {
        FeeReceiverStorage storage $ = getFeeReceiverStorage();
        uint256 balance = $.capToken.balanceOf(address(this));
        uint256 protocolFee = (balance * $.protocolFeePercentage) / 1e27;
        if (protocolFee > 0) $.capToken.safeTransfer($.protocolFeeReceiver, protocolFee);
        emit ProtocolFeeClaimed(protocolFee);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
