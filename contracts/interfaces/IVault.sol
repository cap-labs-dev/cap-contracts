// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVault {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount, address receiver) external;
    function borrow(address asset, uint256 amount, address receiver) external;
    function repay(address asset, uint256 amount) external;
    function rescueERC20(address asset, address receiver) external;
    function pause() external;
    function unpause() external;
    function availableBalance(address asset) external view returns (uint256 amount);
    function utilization(address asset) external view returns (uint256 ratio);
    function currentUtilizationIndex(address asset) external view returns (uint256 index);
    function totalSupplies(address asset) external view returns (uint256 totalSupplies);
    function totalBorrows(address asset) external view returns (uint256 totalBorrows);
    function initialize(address addressProvider) external;
}
