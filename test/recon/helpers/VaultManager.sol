// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseSetup } from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";

import { MockERC4626Tester } from "@recon-temp-tester/MockERC4626Tester.sol";
import { EnumerableSet } from "@recon/EnumerableSet.sol";
import { MockERC20 } from "@recon/MockERC20.sol";

/// @dev Source of truth for the yield vaults being used in the test
/// @notice No vaults should be used in the suite without being added here first
abstract contract VaultManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The current target for this set of variables
    address private __vault;

    /// @notice The list of all vaults being used
    EnumerableSet.AddressSet private _vaults;

    // If the current target is address(0) then it has not been setup yet and should revert
    error VaultNotSetup();
    // Do not allow duplicates
    error VaultExists();
    // Enable only added vaults
    error VaultNotAdded();

    /// @notice Returns the current active vault
    function _getVault() internal view returns (address) {
        if (__vault == address(0)) {
            revert VaultNotSetup();
        }

        return __vault;
    }

    /// @notice Returns all vaults being used
    function _getVaults() internal view returns (address[] memory) {
        return _vaults.values();
    }

    /// @notice Creates a new vault and adds it to the list of vaults
    /// @param asset The asset to create the vault for
    /// @return The address of the new vault
    function _newVault(address asset) internal returns (address) {
        address vault_ = address(new MockERC4626Tester(address(asset)));
        _addVault(vault_);

        __vault = vault_; // sets the vault as the current vault
        return vault_;
    }

    /// @notice Adds a vault to the list of vaults
    /// @param target The address of the vault to add
    function _addVault(address target) internal {
        if (_vaults.contains(target)) {
            revert VaultExists();
        }

        _vaults.add(target);
    }

    /// @notice Removes a vault from the list of vaults
    /// @param target The address of the vault to remove
    function _removeVault(address target) internal {
        if (!_vaults.contains(target)) {
            revert VaultNotAdded();
        }

        _vaults.remove(target);
    }

    /// @notice Switches the current vault based on the entropy
    /// @param entropy The entropy to choose a random vault in the array for switching
    function _switchVault(uint256 entropy) internal {
        address target = _vaults.at(entropy % _vaults.length());
        __vault = target;
    }
}
