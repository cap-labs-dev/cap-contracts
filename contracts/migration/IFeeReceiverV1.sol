// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IFeeReceiverV1
/// @author kexley, Cap Labs
/// @notice Interface for the distribution surface of the v1 FeeReceiver
interface IFeeReceiverV1 {
    /// @notice Send the collected cUSD to the staked token, notifying it once its last release is over
    /// @dev Asks the staked token for `lastNotify` and `lockDuration`, so it reverts against an
    /// address that cannot answer them.
    function distribute() external;
}
