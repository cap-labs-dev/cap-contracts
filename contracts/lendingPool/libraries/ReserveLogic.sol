// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDebtToken } from "../../interfaces/IDebtToken.sol";
import { IPrincipalDebtToken } from "../../interfaces/IPrincipalDebtToken.sol";

import { ValidationLogic } from "./ValidationLogic.sol";
import { Errors } from "./helpers/Errors.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Reserve Logic
/// @author kexley, @capLabs
/// @notice Add, remove or pause reserves on the Lender
library ReserveLogic {
    /// @notice Add asset to the lender
    /// @param $ Lender storage
    /// @param params Parameters for adding an asset
    /// @return filled True if filling in empty space or false if appended
    function addAsset(DataTypes.LenderStorage storage $, DataTypes.AddAssetParams memory params)
        external
        returns (bool filled)
    {
        ValidationLogic.validateAddAsset($, params.asset, params.vault);

        uint256 id;

        for (uint256 i; i < $.reservesCount; ++i) {
            // Fill empty space if available
            if ($.reservesList[i] == address(0)) {
                $.reservesList[i] = params.asset;
                id = i;
                filled = true;
                break;
            }
        }

        if (!filled) {
            require($.reservesCount + 1 < 256, Errors.NO_MORE_RESERVES_ALLOWED);
            id = $.reservesCount;
            $.reservesList[$.reservesCount] = params.asset;
        }

        $.reservesData[params.asset] = DataTypes.ReserveData({
            id: id,
            vault: params.vault,
            principalDebtToken: params.principalDebtToken,
            restakerDebtToken: params.restakerDebtToken,
            interestDebtToken: params.interestDebtToken,
            interestReceiver: params.interestReceiver,
            decimals: params.decimals,
            paused: true,
            realizedInterest: 0
        });
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param $ Lender storage
    /// @param _asset Asset address
    function removeAsset(DataTypes.LenderStorage storage $, address _asset) external {
        ValidationLogic.validateRemoveAsset($, _asset);

        $.reservesList[$.reservesData[_asset].id] = address(0);
        delete $.reservesData[_asset];
    }

    /// @notice Pause an asset from being borrowed
    /// @param $ Lender storage
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(DataTypes.LenderStorage storage $, address _asset, bool _pause) external {
        ValidationLogic.validatePauseAsset($, _asset);
        $.reservesData[_asset].paused = _pause;
    }
}
