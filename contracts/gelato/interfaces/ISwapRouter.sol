// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ISwapRouter {
    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut) external;
}
