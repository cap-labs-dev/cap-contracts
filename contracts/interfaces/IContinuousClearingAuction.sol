// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IContinuousClearingAuction
/// @author kexley, Cap Labs
/// @notice Interface for the ContinuousClearingAuction contract
interface IContinuousClearingAuction {
    /// @notice Get the start block of the auction
    /// @return startBlock Start block of the auction
    function startBlock() external view returns (uint256 startBlock);

    /// @notice Get the end block of the auction
    /// @return endBlock End block of the auction
    function endBlock() external view returns (uint256 endBlock);
}
