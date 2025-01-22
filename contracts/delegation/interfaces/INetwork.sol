// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INetwork {
    function coverage(address agent, address delegator) external view returns (uint256 delegation);
    function slash(address agent, address delegator, address liquidator, uint256 amount) external;
}