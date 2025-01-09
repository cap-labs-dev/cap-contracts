// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAddressProvider} from "../interfaces/IAddressProvider.sol";

/// @title Cap Token
/// @author kexley, @capLabs
/// @notice Token representing the basket of underlying assets
contract CapToken is Initializable, ERC20PermitUpgradeable {
    /// @notice Minter role id
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Burner role id
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @notice Initialize the cap token
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    function initialize(address _addressProvider, string memory _name, string memory _symbol) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
    }

    /// @notice Authorized mint to an address
    /// @param _to Address to mint to
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external {
        addressProvider.checkRole(MINTER_ROLE, msg.sender);
        _mint(_to, _amount);
    }

    /// @notice Authorized burn from an address
    /// @param _from Address to burn from
    /// @param _amount Amount to burn
    function burn(address _from, uint256 _amount) external {
        addressProvider.checkRole(BURNER_ROLE, msg.sender);
        _burn(_from, _amount);
    }
}
