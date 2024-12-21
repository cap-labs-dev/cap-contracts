// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAavePool {
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}
