// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IStakedCap } from "./IStakedCap.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeReceiver {
    /// @custom:storage-location erc7201:cap.storage.FeeReceiver
    struct FeeReceiverStorage {
        IERC20 capToken;
        IStakedCap stakedCapToken;
        address protocolFeeReceiver;
        uint256 protocolFeePercentage;
    }

    /// @dev Emitted when the protocol fee is claimed
    event ProtocolFeeClaimed(uint256 amount);

    /// @dev Emitted when the fees are distributed
    event FeesDistributed(uint256 amount);

    /// @dev Emitted when the protocol fee percentage is set
    event ProtocolFeePercentageSet(uint256 protocolFeePercentage);

    /// @dev Emitted when the protocol fee receiver is set
    event ProtocolFeeReceiverSet(address protocolFeeReceiver);

    /// @dev Invalid protocol fee percentage
    error InvalidProtocolFeePercentage();

    /// @dev No protocol fee receiver set
    error NoProtocolFeeReceiverSet();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Initialize the fee receiver
    /// @param _accessControl Access control address
    /// @param _capToken Cap token address
    /// @param _stakedCapToken Staked cap token address
    function initialize(address _accessControl, address _capToken, address _stakedCapToken) external;

    /// @notice Distribute Fees to the staked cap token
    function distribute() external;

    /// @notice Set protocol fee percentage
    /// @param _protocolFeePercentage Protocol fee percentage
    function setProtocolFeePercentage(uint256 _protocolFeePercentage) external;

    /// @notice Set protocol fee receiver
    /// @param _protocolFeeReceiver Protocol fee receiver address
    function setProtocolFeeReceiver(address _protocolFeeReceiver) external;
}
