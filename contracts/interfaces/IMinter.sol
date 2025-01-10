// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMinter {
    function swapExactTokenForTokens(
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _tokenIn,
        address _tokenOut,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    function redeem(
        uint256 _amountIn,
        uint256[] memory _minAmountOuts,
        address _tokenIn,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256[] memory amountOuts);

    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut);

    function getRedeemAmountOut(address _tokenIn, uint256 _amountIn) external view returns (uint256[] memory amounts);
}
