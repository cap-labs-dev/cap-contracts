// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessUpgradeable} from "../registry/AccessUpgradeable.sol";

/// @title Cap Token
/// @author kexley, @capLabs
/// @notice Token representing the basket of underlying assets
contract CapToken is UUPSUpgradeable, ERC20PermitUpgradeable, AccessUpgradeable {
    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the cap token
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    /// @param _accessControl Access controller
    function initialize(
        string memory _name,
        string memory _symbol,
        address _accessControl
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Access_init(_accessControl);
    }

    /// @notice Authorized mint to an address
    /// @param _to Address to mint to
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external checkRole(this.mint.selector) {
        _mint(_to, _amount);
    }

    /// @notice Authorized burn from an address
    /// @param _from Address to burn from
    /// @param _amount Amount to burn
    function burn(address _from, uint256 _amount) external checkRole(this.burn.selector) {
        _burn(_from, _amount);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override view checkRole(bytes4(0)) {}
}
