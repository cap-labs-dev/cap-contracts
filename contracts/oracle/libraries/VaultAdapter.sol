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
        mapping(address => UtilizationData) utilizationData;
        uint256 maxMultiplier;
        uint256 minMultiplier;
        uint256 rate;
    }

    /// @dev Slope data for an asset
    struct SlopeData {
        uint256 kink;
        uint256 slope0;
        uint256 slope1;
    }

    /// @dev Slope data for an asset
    struct UtilizationData {
        uint256 utilizationMultiplier;
        uint256 index;
        uint256 lastUpdate;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.VaultAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultAdapterStorageLocation =
        0x2b1d5d801322d1007f654ac87d8072a5f5ca4203517edc869ef2aa54addad600;

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
    function rate(address _vault, address _asset) external returns (uint256 latestAnswer) {
        VaultAdapterStorage storage $ = get();

        uint256 elapsed;
        uint256 utilization;
        if (block.timestamp > $.utilizationData[_asset].lastUpdate) {
            uint256 index = IVaultUpgradeable(_vault).currentUtilizationIndex(_asset);
            elapsed = block.timestamp - $.utilizationData[_asset].lastUpdate;

            /// Use average utilization except on the first rate update
            if (elapsed != block.timestamp) {
                utilization = (index - $.utilizationData[_asset].index) / elapsed;
            } else {
                utilization = IVaultUpgradeable(_vault).utilization(_asset);
            }

            $.utilizationData[_asset].index = index;
            $.utilizationData[_asset].lastUpdate = block.timestamp;
        } else {
            utilization = IVaultUpgradeable(_vault).utilization(_asset);
        }

        latestAnswer = _applySlopes(_asset, utilization, elapsed);
    }

    /// @notice Set utilization slopes for an asset
    /// @param _asset Asset address
    /// @param _slopes Slope data
    function setSlopes(address _asset, SlopeData memory _slopes) external checkAccess(this.setSlopes.selector) {
        get().slopeData[_asset] = _slopes;
    }

    /// @notice Set limits for the utilization multiplier
    /// @param _maxMultiplier Maximum slope multiplier
    /// @param _minMultiplier Minimum slope multiplier
    /// @param _rate Rate at which the multiplier shifts
    function setLimits(uint256 _maxMultiplier, uint256 _minMultiplier, uint256 _rate)
        external
        checkAccess(this.setLimits.selector)
    {
        VaultAdapterStorage storage $ = get();
        $.maxMultiplier = _maxMultiplier;
        $.minMultiplier = _minMultiplier;
        $.rate = _rate;
    }

    /// @dev Interest is applied according to where on the slope the current utilization is and the
    /// multiplier depends on the duration and distance the utilization is from the kink point.
    /// All utilization values, kinks, and multipliers are in ray (1e27)
    /// @param _asset Asset address
    /// @param _utilization Utilization ratio in ray (1e27)
    /// @param _elapsed Length of time at the utilization
    /// @return interestRate Interest rate in ray (1e27)
    function _applySlopes(address _asset, uint256 _utilization, uint256 _elapsed)
        internal
        returns (uint256 interestRate)
    {
        VaultAdapterStorage storage $ = get();
        SlopeData memory slopes = $.slopeData[_asset];
        if (_utilization > slopes.kink) {
            uint256 excess = _utilization - slopes.kink;
            $.utilizationData[_asset].utilizationMultiplier *=
                (1e27 + (1e27 * excess / (1e27 - slopes.kink)) * (_elapsed * $.rate / 1e27));

            if ($.utilizationData[_asset].utilizationMultiplier > $.maxMultiplier) {
                $.utilizationData[_asset].utilizationMultiplier = $.maxMultiplier;
            }

            interestRate = (slopes.slope0 + (slopes.slope1 * excess / 1e27))
                * $.utilizationData[_asset].utilizationMultiplier / 1e27;
        } else {
            $.utilizationData[_asset].utilizationMultiplier /=
                (1e27 + (1e27 * (slopes.kink - _utilization) / slopes.kink) * (_elapsed * $.rate / 1e27));

            if ($.utilizationData[_asset].utilizationMultiplier < $.minMultiplier) {
                $.utilizationData[_asset].utilizationMultiplier = $.minMultiplier;
            }

            interestRate =
                (slopes.slope0 * _utilization / slopes.kink) * $.utilizationData[_asset].utilizationMultiplier / 1e27;
        }
    }
}
