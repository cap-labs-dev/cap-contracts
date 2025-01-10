// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAddressProvider {
    function lender() external view returns (address);
    function collateral() external view returns (address);
    function priceOracle() external view returns (address);
    function rateOracle() external view returns (address);
    function vaultDataProvider() external view returns (address);
    function minter() external view returns (address);
    function vaultInstance() external view returns (address);
    function principalDebtTokenInstance() external view returns (address);
    function restakerDebtTokenInstance() external view returns (address);
    function interestDebtTokenInstance() external view returns (address);
    function interestReceiver(address asset) external view returns (address);
    function restakerInterestReceiver(address agent) external view returns (address);
    function checkRole(bytes32 role, address account) external view;
}
