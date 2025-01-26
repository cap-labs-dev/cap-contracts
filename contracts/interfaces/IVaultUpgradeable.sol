// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultUpgradeable {
    function mint(address asset, uint256 amountIn, uint256 minAmountOut, address receiver, uint256 deadline)
        external
        returns (uint256 amountOut);
    function burn(address asset, uint256 amountIn, uint256 minAmountOut, address receiver, uint256 deadline)
        external
        returns (uint256 amountOut);
    function redeem(uint256 amountIn, uint256[] calldata minAmountsOut, address receiver, uint256 deadline)
        external
        returns (uint256[] memory amountsOut);
    function borrow(address asset, uint256 amount, address receiver) external;
    function repay(address asset, uint256 amount) external;
    function pause() external;
    function unpause() external;
    function availableBalance(address asset) external view returns (uint256 amount);
    function utilization(address asset) external view returns (uint256 ratio);
    function currentUtilizationIndex(address asset) external view returns (uint256 index);
    function totalSupplies(address asset) external view returns (uint256 totalSupplies);
    function totalBorrows(address asset) external view returns (uint256 totalBorrows);
    function assets() external view returns (address[] memory assets);
}
