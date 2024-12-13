// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";

/// @title AccessControl
/// @author kexley, @capLabs
/// @notice Access to critical function is controlled through this contract
contract AccessControl is Initializable, AccessControlEnumerableUpgradeable {
    /// @notice Vault admin role
    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN");

    /// @notice Emergency admin role
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN");

    /// @notice Asset listing admin role
    bytes32 public constant ASSET_LISTING_ROLE = keccak256("ASSET_LISTING");

    /// @notice Agent listing admin role
    bytes32 public constant AGENT_LISTING_ROLE = keccak256("AGENT_LISTING");

    /// @notice Agent role
    bytes32 public constant AGENT_ROLE = keccak256("AGENT");

    /// @notice Address provider
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /// @notice Initialize the access controller
    /// @param _provider The address provider
    function initialize(IPoolAddressesProvider _provider) external initializer {
        ADDRESSES_PROVIDER = _provider;
        address admin = provider.getAccessControlAdmin();
        require(admin != address(0), Errors.ACCESS_ADMIN_CANNOT_BE_ZERO);
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(AGENT_ROLE, AGENT_LISTING_ROLE);
    }
}
