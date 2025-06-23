// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title LimitModule
/// @author kexley, @capLabs
/// @notice LimitModule limits the fractional reserve vaults to only be used by the vault
contract LimitModule {
    /// @notice The vault address
    address public immutable vault;

    /// @notice Initialize the LimitModule
    /// @param _vault The vault address
    constructor(address _vault) {
        vault = _vault;
    }

    /// @notice Limit depositor to only one address
    /// @param receiver The address of the receiver of shares
    /// @return limit The maximum amount of shares that can be minted to the receiver
    function available_deposit_limit(address receiver) external view returns (uint256 limit) {
        if (receiver == vault) limit = type(uint256).max;
    }

    /// @notice Limit withdrawals to only one address
    /// @param owner The address of the owner of the shares
    /// @return limit The maximum amount of shares that can be withdrawn
    function available_withdraw_limit(address owner, uint256, /*max_loss*/ address[] calldata /*strategies*/ )
        external
        view
        returns (uint256 limit)
    {
        if (owner == vault) limit = type(uint256).max;
    }
}
