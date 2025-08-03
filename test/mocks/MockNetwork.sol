// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticNetwork } from "../../contracts/interfaces/ISymbioticNetwork.sol";

contract MockNetwork is ISymbioticNetwork {
    function initialize(
        address _accessControl,
        address _networkRegistry,
        address _operatorRegistry,
        address _networkOptInService,
        address _vaultOptInService
    ) external { }

    function registerMiddleware(address _middleware, address _middlewareService) external { }

    function registerVault(address _vault, address _agent) external { }

    function getOperator(address _agent) external pure returns (address) {
        return _agent;
    }

    function deployOperator(address _agent) external returns (address) { }
}
