// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IVaultV1
/// @author kexley, Cap Labs
/// @notice Interface for the unwind surface of v1 cUSD, which is both the vault and its fractional reserve
interface IVaultV1 {
    /// @notice Get the assets the vault holds
    /// @return assetList The asset addresses
    function assets() external view returns (address[] memory assetList);

    /// @notice Get the amount of an asset lent to agents
    /// @param asset The asset address
    /// @return totalBorrow The amount outstanding, in asset units
    function totalBorrows(address asset) external view returns (uint256 totalBorrow);

    /// @notice Get the amount of an asset invested in its fractional reserve vault
    /// @param asset The asset address
    /// @return loanedAmount The amount invested, in asset units
    function loaned(address asset) external view returns (uint256 loanedAmount);

    /// @notice Get the interest the fractional reserve vault has earned and not yet realized
    /// @param asset The asset address
    /// @return interest The unrealized interest, in asset units
    function claimableInterest(address asset) external view returns (uint256 interest);
}
