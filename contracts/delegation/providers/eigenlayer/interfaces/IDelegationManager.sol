    // SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IDelegationManager {
    /// @notice Get the slashable shares in queue for a given operator and strategy
    /// @param operator The operator address
    /// @param strategy The strategy address
    /// @return The slashable shares in queue
    function getSlashableSharesInQueue(address operator, address strategy) external view returns (uint256);

    /// @notice Get the operator shares for a given operator and strategies
    /// @param operator The operator address
    /// @param strategies The strategies
    /// @return The operator shares
    function getOperatorShares(address operator, address[] memory strategies)
        external
        view
        returns (uint256[] memory);
}
