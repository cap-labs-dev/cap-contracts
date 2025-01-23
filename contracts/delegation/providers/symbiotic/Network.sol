// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NetworkStorage } from "./libraries/NetworkStorage.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";
import { AccessUpgradeable } from "../../../access/AccessUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { IMiddleware } from "./interfaces/IMiddleware.sol";

/// @title Cap Symbiotic Network Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract Network is UUPSUpgradeable, AccessUpgradeable {
    /// @notice Initialize
    /// @param _accessControl Access control address
    /// @param _networkRegistry Network registry address
    function initialize(
        address _accessControl,
        address _networkRegistry
    ) external initializer {
        __Access_init(_accessControl);
        INetworkRegistry(_networkRegistry).registerNetwork();
    }

    /// @notice Register middleware contract
    /// @param _middleware Middleware contract
    /// @param _middlewareService Middleware service address
    function registerMiddleware(
        address _middleware,
        address _middlewareService
    ) external checkAccess(this.registerMiddleware.selector) {
        DataTypes.NetworkStorage storage $ = NetworkStorage.get();
        $.middleware = _middleware;
        INetworkMiddlewareService(_middlewareService).setMiddleware(_middleware);
    }

    /// @notice Register vault with Symbiotic
    /// @param _vault Vault address
    function registerVault(address _vault) external checkAccess(this.registerVault.selector) {
        DataTypes.NetworkStorage storage $ = NetworkStorage.get();
        address delegator = IVault(_vault).delegator();
        INetworkRestakeDelegator(delegator).setMaxNetworkLimit(
            IMiddleware($.middleware).subnetworkIdentifier(),
            type(uint256).max
        );
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) {}
}
