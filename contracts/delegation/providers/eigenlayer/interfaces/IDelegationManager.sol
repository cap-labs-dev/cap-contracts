    // SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IDelegationManager {
    function getSlashableSharesInQueue(address operator, address strategy) external view returns (uint256);
}
