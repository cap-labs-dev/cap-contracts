// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {ICollateralHandler} from "./interfaces/ICollateralHandler.sol";

contract Network is 
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant COLLATERAL_ROLE = keccak256("COLLATERAL_ROLE");

    address public collateral;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _registerProvider(address _provider, address _asset) internal virtual {
        ICollateralHandler(collateral).registerProvider(_provider, _asset);
    }

    function collateralByProvider(address, address) external virtual view returns (uint256) {}

    function slashProvider(address _provider, address _operator, uint256 _amount) external virtual {}

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}