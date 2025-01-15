// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICollateralHandler {
    function registerProvider(address provider, address asset) external;
}