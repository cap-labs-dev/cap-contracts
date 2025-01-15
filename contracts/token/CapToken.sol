// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VaultUpgradeable } from "../vault/VaultUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Cap Token
/// @author kexley, @capLabs
/// @notice Token representing the basket of underlying assets
contract CapToken is UUPSUpgradeable, VaultUpgradeable {
    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Cap token
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    /// @param _accessControl Access controller
    /// @param _priceOracle Price oracle address
    /// @param _assets Asset addresses to mint Cap token with
    function initialize(
        string memory _name,
        string memory _symbol,
        address _accessControl,
        address _priceOracle,
        address[] calldata _assets
    ) external initializer {
        __Vault_init(_name, _symbol, _accessControl, _priceOracle, _assets);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
