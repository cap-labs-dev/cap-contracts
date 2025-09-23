// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../access/Access.sol";
import { IVault } from "../../interfaces/IVault.sol";

import { IVaultAdapter } from "../../interfaces/IVaultAdapter.sol";
import { VaultAdapterStorageUtils } from "../../storage/VaultAdapterStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Vault Adapter
/// @author kexley, Cap Labs
/// @notice Market rates are sourced from the Vault
contract VaultAdapter is IVaultAdapter, UUPSUpgradeable, Access, VaultAdapterStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IVaultAdapter
    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IVaultAdapter
    function rate(address _vault, address _asset) external returns (uint256 latestAnswer) {
        UtilizationData storage utilizationData = getVaultAdapterStorage().utilizationData[_vault][_asset];

        uint256 elapsed;
        uint256 utilization;
        if (block.timestamp > utilizationData.lastUpdate) {
            uint256 index = IVault(_vault).currentUtilizationIndex(_asset);
            elapsed = block.timestamp - utilizationData.lastUpdate;

            /// Use average utilization except on the first rate update
            if (elapsed != block.timestamp) {
                utilization = (index - utilizationData.index) / elapsed;
            } else {
                utilization = IVault(_vault).utilization(_asset);
            }

            utilizationData.index = index;
            utilizationData.lastUpdate = block.timestamp;
        } else {
            utilization = IVault(_vault).utilization(_asset);
        }

        latestAnswer = _applySlopes(_vault, _asset, utilization, elapsed);
    }

    /// @inheritdoc IVaultAdapter
    function slopes(address _asset) external view returns (SlopeData memory) {
        return getVaultAdapterStorage().slopeData[_asset];
    }

    /// @inheritdoc IVaultAdapter
    function maxMultiplier() external view returns (uint256) {
        return getVaultAdapterStorage().maxMultiplier;
    }

    /// @inheritdoc IVaultAdapter
    function minMultiplier() external view returns (uint256) {
        return getVaultAdapterStorage().minMultiplier;
    }

    /// @inheritdoc IVaultAdapter
    function multiplierRate() external view returns (uint256) {
        return getVaultAdapterStorage().rate;
    }

    /// @inheritdoc IVaultAdapter
    function setSlopes(address _asset, SlopeData memory _slopes) external checkAccess(this.setSlopes.selector) {
        if (_slopes.kink >= 1e27 || _slopes.kink == 0) revert InvalidKink();
        getVaultAdapterStorage().slopeData[_asset] = _slopes;
        emit SetSlopes(_asset, _slopes);
    }

    /// @inheritdoc IVaultAdapter
    function setLimits(uint256 _maxMultiplier, uint256 _minMultiplier, uint256 _rate)
        external
        checkAccess(this.setLimits.selector)
    {
        VaultAdapterStorage storage $ = getVaultAdapterStorage();
        $.maxMultiplier = _maxMultiplier;
        $.minMultiplier = _minMultiplier;
        $.rate = _rate;
        emit SetLimits(_maxMultiplier, _minMultiplier, _rate);
    }

    /// @dev Interest is applied according to where on the slope the current utilization is and the
    /// multiplier depends on the duration and distance the utilization is from the kink point.
    /// All utilization values, kinks, and multipliers are in ray (1e27)
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @param _utilization Utilization ratio in ray (1e27)
    /// @param _elapsed Length of time at the utilization
    /// @return interestRate Interest rate in ray (1e27)
    function _applySlopes(address _vault, address _asset, uint256 _utilization, uint256 _elapsed)
        internal
        returns (uint256 interestRate)
    {
        VaultAdapterStorage storage $ = getVaultAdapterStorage();
        UtilizationData storage utilizationData = $.utilizationData[_vault][_asset];
        SlopeData memory _slopes = $.slopeData[_asset];
        if (_utilization > _slopes.kink) {
            uint256 excess = _utilization - _slopes.kink;
            utilizationData.multiplier = utilizationData.multiplier
                * (1e27 + (1e27 * excess / (1e27 - _slopes.kink)) * _elapsed * $.rate / 1e27) / 1e27;

            if (utilizationData.multiplier > $.maxMultiplier) {
                utilizationData.multiplier = $.maxMultiplier;
            }

            interestRate = (_slopes.slope0 + (_slopes.slope1 * excess / 1e27)) * utilizationData.multiplier / 1e27;
        } else {
            utilizationData.multiplier = utilizationData.multiplier * 1e27
                / (1e27 + (1e27 * (_slopes.kink - _utilization) / _slopes.kink) * _elapsed * $.rate / 1e27);

            if (utilizationData.multiplier < $.minMultiplier) {
                utilizationData.multiplier = $.minMultiplier;
            }

            interestRate = (_slopes.slope0 * _utilization / _slopes.kink) * utilizationData.multiplier / 1e27;
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
