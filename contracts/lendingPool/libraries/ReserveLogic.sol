// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPToken } from "../../interfaces/IPToken.sol";

import { Errors } from './helpers/Errors.sol';
import { ValidationLogic } from "./ValidationLogic.sol";
import { CloneLogic } from "./CloneLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

library ReserveLogic {
    /// @notice Add asset to the possible lending
    /// @param reservesData Reserve mapping
    /// @param reservesList Mapping of all reserves
    /// @param params Parameters for adding an asset
    /// @return filled True if filling in empty space or false if appended
    function addAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        DataTypes.AddAssetParams memory params
    ) external returns (bool filled) {
        ValidationLogic.validateAddAsset(reservesData, params.asset, params.vault);

        uint256 id;

        for (uint256 i; i < params.reserveCount; ++i) {
            // Fill empty space if available
            if (reservesList[i] == address(0)) {
                reservesList[i] = params.asset;
                id = i;
                filled = true;
                break;
            }
        }

        if (!filled) {
            require(params.reserveCount + 1 < 256, Errors.NO_MORE_RESERVES_ALLOWED);
            id = params.reserveCount;
            reservesList[params.reserveCount] = params.asset;
        }

        address pToken = CloneLogic.clone(params.pTokenInstance);
        IPToken(pToken).initialize(params.asset);

        reservesData[params.asset] = DataTypes.ReserveData({
            id: id,
            vault: params.vault,
            pToken: pToken,
            paused: false
        });
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        address _asset
    ) external {
        ValidationLogic.validateRemoveAsset(reservesData, _asset);

        reservesList[reservesData[_asset].id] = address(0);
        delete reservesData[_asset];
    }

    /// @notice Pause an asset
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(
        mapping(address => DataTypes.ReserveData) storage reservesData,
        address _asset,
        bool _pause
    ) external {
        ValidationLogic.validatePauseAsset(reservesData, _asset);
        reservesData[_asset].paused = _pause;
    }
}
