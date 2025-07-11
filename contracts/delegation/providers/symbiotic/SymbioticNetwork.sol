// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISymbioticNetwork
    function initialize(address _accessControl, address _networkRegistry) external initializer {
        __Access_init(_accessControl);
        INetworkRegistry(_networkRegistry).registerNetwork();
    }

    /// @inheritdoc ISymbioticNetwork
    function registerMiddleware(address _middleware, address _middlewareService)
        external
        checkAccess(this.registerMiddleware.selector)
    {
        getSymbioticNetworkStorage().middleware = _middleware;
        INetworkMiddlewareService(_middlewareService).setMiddleware(_middleware);
    }

    /// @inheritdoc ISymbioticNetwork
    function registerVault(address _vault, address _agent) external checkAccess(this.registerVault.selector) {
        address delegator = IVault(_vault).delegator();
        IOperatorNetworkSpecificDelegator(delegator).setMaxNetworkLimit(
            ISymbioticNetworkMiddleware(getSymbioticNetworkStorage().middleware).subnetworkIdentifier(_agent),
            type(uint256).max
        );
    }

    function setDelegation(address _vault, address _agent, uint256 _amount) external 
    // todo: enable access control
    //checkAccess(this.setDelegation.selector)
    {
        address delegator = IVault(_vault).delegator();
        IOperatorNetworkSpecificDelegator(delegator).setMaxNetworkLimit(
            ISymbioticNetworkMiddleware(getSymbioticNetworkStorage().middleware).subnetworkIdentifier(_agent), _amount
        );
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
