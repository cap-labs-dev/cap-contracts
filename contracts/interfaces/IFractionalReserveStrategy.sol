// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IFractionalReserveStrategy {
    function report() external returns (uint256 profit, uint256 loss);
    function setKeeper(address _keeper) external;
}
