// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMiddleware {
    function registerVault(address vault) external;
    function subnetworkIdentifier() external view returns (uint96);
    function subnetwork() external view returns (bytes32);
}