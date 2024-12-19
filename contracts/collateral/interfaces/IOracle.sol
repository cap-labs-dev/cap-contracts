// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    function price(address _asset) external view returns (uint256);
}