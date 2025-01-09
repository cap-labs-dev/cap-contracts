// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAddressProvider {
    function LENDER_ADMIN() external view returns (bytes32);
    function accessControl() external view returns (address);
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

    function initialize(address accessControl) external;
    function setAccessControl(address _accessControl) external;
    function setLender(address _lender) external;
    function setCollateral(address _collateral) external;
    function setPriceOracle(address _priceOracle) external;
    function setRateOracle(address _rateOracle) external;
    function setVaultDataProvider(address _vaultDataProvider) external;
    function setMinter(address _minter) external;
    function setVaultInstance(address _vaultInstance) external;
    function setPrincipalDebtTokenInstance(address _principalDebtTokenInstance) external;
    function setRestakerDebtTokenInstance(address _restakerDebtTokenInstance) external;
    function setInterestDebtTokenInstance(address _interestDebtTokenInstance) external;
    function setInterestReceiver(address _asset, address _receiver) external;
    function setRestakerInterestReceiver(address _agent, address _receiver) external;
}
