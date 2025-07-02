// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ILimitModule } from "../interfaces/ILimitModule.sol";

/// @title LimitModule
/// @author kexley, Cap Labs
/// @notice LimitModule limits the fractional reserve vaults to only be used by the vault
contract LimitModule is ILimitModule {
    /// @inheritdoc ILimitModule
    address public immutable vault;

    /// @notice Initialize the LimitModule
    /// @param _vault The vault address
    constructor(address _vault) {
        vault = _vault;
    }

    /// @inheritdoc ILimitModule
    function available_deposit_limit(address receiver) external view returns (uint256 limit) {
        if (receiver == vault) limit = type(uint256).max;
    }

    /// @inheritdoc ILimitModule
    function available_withdraw_limit(address owner, uint256, /*max_loss*/ address[] calldata /*strategies*/ )
        external
        view
        returns (uint256 limit)
    {
        if (owner == vault) limit = type(uint256).max;
    }
}
