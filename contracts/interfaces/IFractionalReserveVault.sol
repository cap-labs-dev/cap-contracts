// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IFractionalReserveVault {
    function get_default_queue() external view returns (address[] memory);
    function process_report(address _strategy) external returns (uint256 profit, uint256 loss);
}
