// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IDelegation {
    function coverage(address agent) external view returns (uint256 coverage);
    function slash(address agent, address receiver, uint256 liquidatedValue) external;
    function ltv(address agent) external view returns (uint256 ltv);
    function liquidationThreshold(address agent) external view returns (uint256 liquidationThreshold);
    function delegators(address agent) external view returns (address[] memory);
}
