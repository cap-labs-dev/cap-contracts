// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAddressProvider {
    function accessControl() external view returns (address);
    function lender() external view returns (address);
    function collateral() external view returns (address);
    function oracle() external view returns (address);
    function interestReceiver(address asset) external view returns (address);
    function restakerInterestReceiver(address agent) external view returns (address);
}
