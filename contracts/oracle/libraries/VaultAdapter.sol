// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../../access/AccessUpgradeable.sol";
import { IVaultUpgradeable } from "../../interfaces/IVaultUpgradeable.sol";

/// @title Vault Adapter
/// @author kexley, @capLabs
/// @notice Market rates are sourced from the Vault
contract VaultAdapter is AccessUpgradeable {
    /// @custom:storage-location erc7201:cap.storage.VaultAdapter
    struct VaultAdapterStorage {
        mapping(address => SlopeData) slopeData;
    }

    /// @dev Slope data for an asset
    struct SlopeData {
        uint256 kink;
        uint256 slope0;
        uint256 slope1;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.VaultAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultAdapterStorageLocation = 0x2b1d5d801322d1007f654ac87d8072a5f5ca4203517edc869ef2aa54addad600;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (VaultAdapterStorage storage $) {
        assembly {
            $.slot := VaultAdapterStorageLocation
        }
    }

    /// @notice Fetch borrow rate for an asset from the Vault
    /// @param _vault Vault address
    /// @param _asset Asset to fetch rate for
    function rate(address _vault, address _asset) external view returns (uint256 latestAnswer) {
        uint256 utilization = IVaultUpgradeable(_vault).utilization(_asset);
        latestAnswer = _applySlopes(_asset, utilization);
    }

    /// @notice Set utilization slopes for an asset
    /// @param _asset Asset address
    /// @param _slopes Slope data
    function setSlopes(address _asset, SlopeData memory _slopes) external checkAccess(this.setSlopes.selector) {
        get().slopeData[_asset] = _slopes;
    }

    /// @dev Interest rate slopes
    /// @param _asset Asset address
    /// @return interestRate Interest rate
    function _applySlopes(address _asset, uint256 _utilization) internal view returns (uint256 interestRate) {
        SlopeData memory slopes = get().slopeData[_asset];
        if (_utilization > slopes.kink) {
            uint256 excess = _utilization - slopes.kink;
            interestRate = slopes.slope0 + (slopes.slope1 * excess / 1e27);
        } else {
            interestRate = slopes.slope0 * _utilization / slopes.kink;
        }
    }
}
