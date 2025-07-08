// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IStakedCap } from "./IStakedCap.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFeeReceiver
/// @author weso, Cap Labs
/// @notice Interface for the FeeReceiver contract
interface IFeeReceiver {
    /// @dev Storage for the FeeReceiver contract
    /// @param capToken Cap token address
    /// @param stakedCapToken Staked cap token address
    /// @param protocolFeeReceiver Protocol fee receiver address
    /// @param protocolFeePercentage Protocol fee percentage
    struct FeeReceiverStorage {
        IERC20 capToken;
        IStakedCap stakedCapToken;
        address protocolFeeReceiver;
        uint256 protocolFeePercentage;
    }

    /// @dev Emitted when the cap token is set
    event CapTokenSet(address capToken);

    /// @dev Emitted when the fees are distributed
    event FeesDistributed(uint256 amount);

    /// @dev Emitted when the protocol fee is claimed
    event ProtocolFeeClaimed(uint256 amount);

    /// @dev Emitted when the protocol fee percentage is set
    event ProtocolFeePercentageSet(uint256 protocolFeePercentage);

    /// @dev Emitted when the protocol fee receiver is set
    event ProtocolFeeReceiverSet(address protocolFeeReceiver);

    /// @dev Emitted when the staked cap token is set
    event StakedCapTokenSet(address stakedCapToken);

    /// @dev Invalid protocol fee percentage
    error InvalidProtocolFeePercentage();

    /// @dev No protocol fee receiver set
    error NoProtocolFeeReceiverSet();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @notice Initialize the FeeReceiver contract
    /// @param _accessControl Access control address
    /// @param _capToken Cap token address
    /// @param _stakedCapToken Staked cap token address
    function initialize(address _accessControl, address _capToken, address _stakedCapToken) external;

    /// @notice Distribute fees to the staked cap token
    function distribute() external;

    /// @notice Set cap token
    /// @param _capToken Cap token address
    function setCapToken(address _capToken) external;

    /// @notice Set staked cap token
    /// @param _stakedCapToken Staked cap token address
    function setStakedCapToken(address _stakedCapToken) external;

    /// @notice Set protocol fee percentage
    /// @param _protocolFeePercentage Protocol fee percentage
    function setProtocolFeePercentage(uint256 _protocolFeePercentage) external;

    /// @notice Set protocol fee receiver
    /// @param _protocolFeeReceiver Protocol fee receiver address
    function setProtocolFeeReceiver(address _protocolFeeReceiver) external;
}
