// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICapNotify {
    struct CapNotifyStorage {
        address feeReceiver;
        address stakedCap;
    }
    /// @notice Initialize the CapNotify contract
    /// @param _feeReceiver Fee receiver address
    /// @param _stakedCap Staked cap address

    function initialize(address _feeReceiver, address _stakedCap) external;

    /// @notice Notify the fee receiver
    function notify() external;

    /// @notice Gelato checker
    function checker() external view returns (bool canExec, bytes memory execPayload);
}
