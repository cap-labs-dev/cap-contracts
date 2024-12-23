// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Cap Token
/// @author kexley, @capLabs
/// @notice Token representing the basket of underlying assets
contract CapToken is Initializable, ERC20PermitUpgradeable, AccessControlEnumerableUpgradeable {

    /// @notice Minter role id
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Burner role id
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Initialize the cap token
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    function initialize(string memory _name, string memory _symbol) initializer external {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Authorized mint to an address
    /// @param _to Address to mint to
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external onlyRole(MINTER_ROLE) {
        _mint(_to, _amount);
    }

    /// @notice Authorized burn from an address
    /// @param _from Address to burn from
    /// @param _amount Amount to burn
    function burn(address _from, uint256 _amount) external onlyRole(BURNER_ROLE) {
        _burn(_from, _amount);
    }
}
