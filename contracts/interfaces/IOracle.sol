// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    function getPrice(address asset) external view returns (uint256 price);
    function marketIndex(address asset) external view returns (uint256 index);
    function agentIndex(address agent) external view returns (uint256 index);
}