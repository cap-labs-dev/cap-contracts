// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlEnumerableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessControl
/// @author kexley, @capLabs
/// @notice Granular access control for each function on each contract
contract AccessControl is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    /// @notice Initialize the default admin
    /// @param _admin Default admin address
    function initialize(address _admin) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(role(this.grantAccess.selector, address(this)), _admin);
    }

    /// @notice Check a specific method access is granted to an address
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _caller Address to check role for
    function checkAccess(bytes4 _selector, address _contract, address _caller) external view {
        _checkRole(role(_selector, _contract), _caller);
    }

    /// @dev Grant access to a specific method on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @param _address Address to grant role to
    function grantAccess(bytes4 _selector, address _contract, address _address) public {
        _checkRole(role(this.grantAccess.selector, address(this)), msg.sender);
        _grantRole(role(_selector, _contract), _address);
    }

    /// @notice Fetch role id for a function selector on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @return roleId Role id
    function role(bytes4 _selector, address _contract) public pure returns (bytes32 roleId) {
        roleId = bytes32(abi.encodePacked(_selector, _contract));
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
