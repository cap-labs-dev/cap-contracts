// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ILimitModule
/// @author kexley, Cap Labs
/// @notice Interface for the LimitModule contract
interface ILimitModule {
    /// @notice Limit depositor to only one address
    /// @param receiver The address of the receiver of shares
    /// @return limit The maximum amount of shares that can be minted to the receiver
    function available_deposit_limit(address receiver) external view returns (uint256 limit);

    /// @notice Limit withdrawals to only one address
    /// @param owner The address of the owner of the shares
    /// @param max_loss The maximum loss that can be incurred
    /// @param strategies The strategies that can be used to mitigate the loss
    /// @return limit The maximum amount of shares that can be withdrawn
    function available_withdraw_limit(address owner, uint256 max_loss, address[] calldata strategies)
        external
        view
        returns (uint256 limit);

    /// @notice The vault address
    /// @return vault The vault address
    function vault() external view returns (address vault);
}
