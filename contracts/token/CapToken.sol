// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAddressProvider} from "../interfaces/IAddressProvider.sol";

/// @title Cap Token
/// @author kexley, @capLabs
/// @notice Token representing the basket of underlying assets
contract CapToken is UUPSUpgradeable, ERC20PermitUpgradeable {
    /// @notice Cap token admin role id
    bytes32 public constant CAP_ADMIN = keccak256("CAP_ADMIN");

    /// @notice Cap token minter role id
    bytes32 public constant CAP_MINTER = keccak256("CAP_MINTER");

    /// @notice Cap token burner role id
    bytes32 public constant CAP_BURNER = keccak256("CAP_BURNER");

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the cap token
    /// @param _addressProvider Address provider
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    function initialize(
        address _addressProvider,
        string memory _name,
        string memory _symbol
    ) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
    }

    /// @notice Authorized mint to an address
    /// @param _to Address to mint to
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external {
        addressProvider.checkRole(CAP_MINTER, msg.sender);
        _mint(_to, _amount);
    }

    /// @notice Authorized burn from an address
    /// @param _from Address to burn from
    /// @param _amount Amount to burn
    function burn(address _from, uint256 _amount) external {
        addressProvider.checkRole(CAP_BURNER, msg.sender);
        _burn(_from, _amount);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override view {
        addressProvider.checkRole(CAP_ADMIN, msg.sender);
    }
}
