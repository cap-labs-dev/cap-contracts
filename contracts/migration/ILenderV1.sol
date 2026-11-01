// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title ILenderV1
/// @author kexley, Cap Labs
/// @notice Interface for the reserve lookup of the v1 Lender
interface ILenderV1 {
    /// @notice Get the reserve configuration for an asset
    /// @param asset The asset address
    /// @return id The reserve id
    /// @return vault The vault the reserve borrows from
    /// @return debtToken The token tracking what agents owe, accrued interest included
    /// @return interestReceiver The receiver of realized vault interest
    /// @return decimals The asset decimals
    /// @return paused Whether the reserve is paused
    /// @return minBorrow The minimum borrow
    function reservesData(address asset)
        external
        view
        returns (
            uint256 id,
            address vault,
            address debtToken,
            address interestReceiver,
            uint8 decimals,
            bool paused,
            uint256 minBorrow
        );
}
