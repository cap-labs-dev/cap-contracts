// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface INetwork {
    function coverage(address agent) external view returns (uint256 delegation);
    function slashableCollateral(address agent, uint48 timestamp) external view returns (uint256 slashableCollateral);
    function slash(address agent, address liquidator, uint256 amount, uint48 timestamp) external;
    function distributeRewards(address agent, address asset) external;
}
