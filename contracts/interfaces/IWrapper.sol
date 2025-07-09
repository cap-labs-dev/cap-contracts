// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Wrapper
/// @author kexley, Cap Labs
/// @notice Token wrapper where any donations are skimmed to the donation receiver
interface IWrapper {
    /// @dev Storage for the wrapper
    /// @param donationReceiver Donation receiver address
    struct WrapperStorage {
        address donationReceiver;
    }

    /// @notice Emitted when the donation receiver is set
    /// @param donationReceiver The donation receiver address
    event SetDonationReceiver(address donationReceiver);

    /// @notice Emitted when donations are skimmed
    /// @param donationReceiver The donation receiver address
    /// @param amount The amount of donations skimmed
    event Skim(address indexed donationReceiver, uint256 amount);

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Initialize the wrapper
    /// @dev The name and symbol are derived from the asset
    /// @param _accessControl Access controller
    /// @param _donationReceiver Donation receiver
    /// @param _asset Asset to wrap
    function initialize(address _accessControl, address _donationReceiver, address _asset) external;

    /// @notice Set the donation receiver
    /// @param _donationReceiver Address of the donation receiver
    function setDonationReceiver(address _donationReceiver) external;

    /// @notice Skim donations from the wrapper to the donation receiver
    /// @return amount The amount of donations skimmed
    function skim() external returns (uint256 amount);

    /// @notice Get the donation receiver
    /// @return donationReceiverAddress The donation receiver address
    function donationReceiver() external view returns (address donationReceiverAddress);

    /// @notice Get the amount of donations that can be skimmed
    /// @return amount The amount of donations that can be skimmed
    function skimmable() external view returns (uint256 amount);
}
