// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICollateralHandler {
    function registerProvider(address provider, bool isRegistered) external;
}

abstract contract Network {

    address public collateralHandler;

    function _registerProvider(address _provider, bool _isRegistered) internal virtual {
        ICollateralHandler(collateralHandler).registerProvider(_provider, _isRegistered);
    }
}