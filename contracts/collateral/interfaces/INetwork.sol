// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INetwork {
    function collateralByProvider(address _provider) external view returns (uint256);
    function slashProvider(address _provider, uint256 _amount) external;
}
