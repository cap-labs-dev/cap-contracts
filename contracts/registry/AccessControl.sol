// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessControl
/// @author kexley, @capLabs
/// @notice Basic access control contract
contract AccessControl is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    /// @notice Initialize the default admin
    /// @param _admin Default admin address
    function initialize(address _admin) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Check role is held by the account, revert overwise
    /// @param _role Role id
    /// @param _account Address to check role for
    function checkRole(bytes32 _role, address _account) external view {
        _checkRole(_role, _account);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
