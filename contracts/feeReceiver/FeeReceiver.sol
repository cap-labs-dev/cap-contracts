// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";

import { IStakedCap } from "../interfaces/IStakedCap.sol";
import { FeeReceiverStorageUtils } from "../storage/FeeReceiverStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Fee Receiver
/// @author weso, @capLabs
/// @notice Fee receiver contract
contract FeeReceiver is IFeeReceiver, UUPSUpgradeable, Access, FeeReceiverStorageUtils {
    using SafeERC20 for IERC20;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the fee receiver
    /// @param _accessControl Access control address
    /// @param _capToken Cap token address
    /// @param _stakedCapToken Staked cap token address
    function initialize(address _accessControl, address _capToken, address _stakedCapToken) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        if (address(_capToken) == address(0) || address(_stakedCapToken) == address(0)) revert ZeroAddressNotValid();

        IFeeReceiver.FeeReceiverStorage storage s = get();
        s.capToken = IERC20(_capToken);
        s.stakedCapToken = IStakedCap(_stakedCapToken);
    }

    /// @notice Distribute Fees to the staked cap token
    function distribute() external {
        IFeeReceiver.FeeReceiverStorage storage s = get();
        if (s.capToken.balanceOf(address(this)) > 0) {
            if (s.protocolFeePercentage > 0) _claimProtocolFees();
            s.capToken.safeTransfer(address(s.stakedCapToken), s.capToken.balanceOf(address(this)));
            s.stakedCapToken.notify();
            emit Notify(s.capToken.balanceOf(address(this)));
        }
    }

    /// @notice Claim protocol fees
    /// @dev Transfers the protocol fee to the protocol fee receiver
    function _claimProtocolFees() private {
        IFeeReceiver.FeeReceiverStorage storage s = get();
        uint256 balance = s.capToken.balanceOf(address(this));
        uint256 protocolFee = (balance * s.protocolFeePercentage) / 1e18;
        if (protocolFee > 0) s.capToken.safeTransfer(s.protocolFeeReceiver, protocolFee);
        emit ProtocolFeeClaimed(protocolFee);
    }

    /// @notice Set protocol fee percentage
    /// @param _protocolFeePercentage Protocol fee percentage
    function setProtocolFeePercentage(uint256 _protocolFeePercentage)
        external
        checkAccess(this.setProtocolFeePercentage.selector)
    {
        IFeeReceiver.FeeReceiverStorage storage s = get();
        if (_protocolFeePercentage > 1e18) revert InvalidProtocolFeePercentage();
        if (s.protocolFeeReceiver == address(0)) revert NoProtocolFeeReceiverSet();
        s.protocolFeePercentage = _protocolFeePercentage;
        emit ProtocolFeePercentageSet(_protocolFeePercentage);
    }

    /// @notice Set protocol fee receiver
    /// @param _protocolFeeReceiver Protocol fee receiver address
    function setProtocolFeeReceiver(address _protocolFeeReceiver)
        external
        checkAccess(this.setProtocolFeeReceiver.selector)
    {
        IFeeReceiver.FeeReceiverStorage storage s = get();
        s.protocolFeeReceiver = _protocolFeeReceiver;
        emit ProtocolFeeReceiverSet(_protocolFeeReceiver);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
