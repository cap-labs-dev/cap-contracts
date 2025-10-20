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

    /// @notice Deposit tokens into a strategy
    /// @param strategy The strategy
    /// @param token The token
    /// @param amount The amount
    function depositIntoStrategy(address strategy, address token, uint256 amount) external;
}
