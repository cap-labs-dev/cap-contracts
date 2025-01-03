// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracleAdapter {
    function price(address source, address asset) external view returns (uint256 price);
    function rate(address source, address asset) external view returns (uint256 rate);
}