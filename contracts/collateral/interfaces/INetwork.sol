// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INetwork {
    function collateralByProvider(address _operator, address _provider) external view returns (uint256);
    function slash(address _provider, address _liquidator, uint256 _amount) external;
}