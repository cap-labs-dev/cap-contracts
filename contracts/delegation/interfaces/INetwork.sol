// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface INetwork {
    function coverage(address agent) external view returns (uint256 delegation);
    function slash(address agent, address liquidator, uint256 amount) external;
}