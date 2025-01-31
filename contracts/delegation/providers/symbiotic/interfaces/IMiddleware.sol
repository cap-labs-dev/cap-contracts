// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IMiddleware {
    // function registerVault(address vault) external;
    function subnetworkIdentifier(address _agent) external view returns (uint96);
    function subnetwork(address _agent) external view returns (bytes32);
}
