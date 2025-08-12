// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";

import { ISymbioticOperator, SymbioticOperator } from "./SymbioticOperator.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISymbioticNetworkMiddleware } from "../../../interfaces/ISymbioticNetworkMiddleware.sol";

import { ISymbioticNetwork } from "../../../interfaces/ISymbioticNetwork.sol";
import { SymbioticNetworkStorageUtils } from "../../../storage/SymbioticNetworkStorageUtils.sol";

import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

/// @title Symbiotic Network
/// @author weso, Cap Labs
/// @notice This contract manages the symbiotic network
contract SymbioticNetwork is ISymbioticNetwork, UUPSUpgradeable, Access, SymbioticNetworkStorageUtils {
    /// @dev Operator deployed
    event OperatorDeployed(address indexed agent, address indexed operator);
    /// @dev Vault registered
    event VaultRegistered(address indexed vault, address indexed agent, address indexed operator);
    /// @dev Operator already deployed

    error OperatorAlreadyDeployed(address agent);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISymbioticNetwork
    function initialize(
        address _accessControl,
        address _networkRegistry,
        address _operatorRegistry,
        address _networkOptInService,
        address _vaultOptInService,
        address _middleware,
        address _middlewareService
    ) external initializer {
        __Access_init(_accessControl);
        INetworkRegistry(_networkRegistry).registerNetwork();
        getSymbioticNetworkStorage().networkOptInService = _networkOptInService;
        getSymbioticNetworkStorage().vaultOptInService = _vaultOptInService;
        getSymbioticNetworkStorage().operatorRegistry = _operatorRegistry;
        getSymbioticNetworkStorage().operatorImplementation = address(new SymbioticOperator());
        _registerMiddleware(_middleware, _middlewareService);
    }

    /// @inheritdoc ISymbioticNetwork
    function getOperator(address _agent) public view returns (address) {
        return getSymbioticNetworkStorage().agentToOperator[_agent];
    }

    /// @inheritdoc ISymbioticNetwork
    function registerVault(address _vault, address _agent) external checkAccess(this.registerVault.selector) {
        address operator = getOperator(_agent);
        address delegator = IVault(_vault).delegator();
        IOperatorNetworkSpecificDelegator(delegator).setMaxNetworkLimit(
            ISymbioticNetworkMiddleware(getSymbioticNetworkStorage().middleware).subnetworkIdentifier(operator),
            type(uint256).max
        );

        ISymbioticOperator(operator).optIntoVault(getSymbioticNetworkStorage().vaultOptInService, _vault);

        emit VaultRegistered(_vault, _agent, operator);
    }

    /// @inheritdoc ISymbioticNetwork
    function deployOperator(address _agent) external returns (address operator) {
        if (getOperator(_agent) != address(0)) revert OperatorAlreadyDeployed(_agent);

        SymbioticNetworkStorage storage $ = getSymbioticNetworkStorage();

        operator = Clones.clone($.operatorImplementation);
        ISymbioticOperator(operator).initialize(_agent, $.networkOptInService, $.operatorRegistry, address(this));

        $.agentToOperator[_agent] = operator;
        emit OperatorDeployed(_agent, operator);
    }

    /// @dev Register middleware contract
    /// @param _middleware Middleware contract
    /// @param _middlewareService Middleware service address
    function _registerMiddleware(address _middleware, address _middlewareService) private {
        getSymbioticNetworkStorage().middleware = _middleware;
        INetworkMiddlewareService(_middlewareService).setMiddleware(_middleware);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
