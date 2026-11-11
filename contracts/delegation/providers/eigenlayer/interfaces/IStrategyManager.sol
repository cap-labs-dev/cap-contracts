// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAllocationManager } from "./IAllocationManager.sol";

interface IStrategyManager {
    /// @notice Clear burn or redistributable shares for a given operator set and strategy
    /// @param operatorSet The operator set
    /// @param slashId The slash id
    /// @param strategy The strategy
    function clearBurnOrRedistributableSharesByStrategy(
        IAllocationManager.OperatorSet calldata operatorSet,
        uint256 slashId,
        address strategy
    ) external;

    /// @notice Returns the shares of a strategy that are still waiting to be cleared for a given slash
    /// @dev Returns 0 once the shares have been cleared (by anyone)
    /// @param operatorSet The operator set
    /// @param slashId The slash id
    /// @param strategy The strategy
    /// @return The uncleared shares for the strategy in the given slash
    function getBurnOrRedistributableShares(
        IAllocationManager.OperatorSet calldata operatorSet,
        uint256 slashId,
        address strategy
    ) external view returns (uint256);

    /// @notice Returns the block number after which the given slash's shares may be cleared
    /// @param operatorSet The operator set
    /// @param slashId The slash id
    /// @return The block number after which clearing is permitted
    function getSlashResolutionBlock(IAllocationManager.OperatorSet calldata operatorSet, uint256 slashId)
        external
        view
        returns (uint32);

    /// @notice Deposit tokens into a strategy
    /// @param strategy The strategy
    /// @param token The token
    /// @param amount The amount
    function depositIntoStrategy(address strategy, address token, uint256 amount) external;
}
