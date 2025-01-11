// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAddressProvider {
    function accessControl() external view returns (address);
    function lender() external view returns (address);
    function collateral() external view returns (address);
    function priceOracle() external view returns (address);
    function rateOracle() external view returns (address);
    function vault(address capToken) external view returns (address);
    function minter() external view returns (address);
    function interestReceiver(address asset) external view returns (address);
    function restakerInterestReceiver(address agent) external view returns (address);
    function checkRole(bytes32 role, address account) external view;
}
