// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {INetworkRegistry} from "../../interfaces/symbiotic/INetworkRegistry.sol";
import {INetworkMiddlewareService} from "../../interfaces/symbiotic/INetworkMiddlewareService.sol";

contract CapSymbioticNetwork is 
    OwnableUpgradeable, 
    UUPSUpgradeable
{
    function initialize(
        address _networkRegistry,
        address _networkMiddlewareService
    ) initializer external {
        __Ownable_init(msg.sender);

        INetworkRegistry(_networkRegistry).registerNetwork();
        INetworkMiddlewareService(_networkMiddlewareService).setMiddleware(address(this));
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}