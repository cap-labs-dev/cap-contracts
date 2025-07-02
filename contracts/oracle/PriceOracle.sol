// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IOracleTypes } from "../interfaces/IOracleTypes.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { PriceOracleStorageUtils } from "../storage/PriceOracleStorageUtils.sol";

/// @title Price Oracle
/// @author kexley, Cap Labs
/// @dev Payloads are stored on this contract and calculation logic is hosted on external libraries
abstract contract PriceOracle is IPriceOracle, Access, PriceOracleStorageUtils {
    /// @inheritdoc IPriceOracle
    function setPriceOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceOracleData.selector)
    {
        getPriceOracleStorage().oracleData[_asset] = _oracleData;
        emit SetPriceOracleData(_asset, _oracleData);
    }

    /// @inheritdoc IPriceOracle
    function setPriceBackupOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceBackupOracleData.selector)
    {
        getPriceOracleStorage().backupOracleData[_asset] = _oracleData;
        emit SetPriceBackupOracleData(_asset, _oracleData);
    }

    /// @inheritdoc IPriceOracle
    function setStaleness(address _asset, uint256 _staleness) external checkAccess(this.setStaleness.selector) {
        getPriceOracleStorage().staleness[_asset] = _staleness;
        emit SetStaleness(_asset, _staleness);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address _asset) external view returns (uint256 price, uint256 lastUpdated) {
        PriceOracleStorage storage $ = getPriceOracleStorage();
        IOracleTypes.OracleData memory data = $.oracleData[_asset];

        (price, lastUpdated) = _getPrice(data.adapter, data.payload);

        if (price == 0 || _isStale(_asset, lastUpdated)) {
            data = $.backupOracleData[_asset];
            (price, lastUpdated) = _getPrice(data.adapter, data.payload);

            if (price == 0 || _isStale(_asset, lastUpdated)) revert PriceError(_asset);
        }
    }

    /// @inheritdoc IPriceOracle
    function priceOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data) {
        data = getPriceOracleStorage().oracleData[_asset];
    }

    /// @inheritdoc IPriceOracle
    function priceBackupOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data) {
        data = getPriceOracleStorage().backupOracleData[_asset];
    }

    /// @inheritdoc IPriceOracle
    function staleness(address _asset) external view returns (uint256 assetStaleness) {
        assetStaleness = getPriceOracleStorage().staleness[_asset];
    }

    /// @dev Initialize the price oracle
    /// @param _accessControl Access control address
    function __PriceOracle_init(address _accessControl) internal onlyInitializing {
        __Access_init(_accessControl);
        __PriceOracle_init_unchained();
    }

    /// @dev Initialize unchained is empty
    function __PriceOracle_init_unchained() internal onlyInitializing { }

    /// @dev Calculate price using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return price Calculated price
    /// @return lastUpdated Last updated timestamp
    function _getPrice(address _adapter, bytes memory _payload)
        private
        view
        returns (uint256 price, uint256 lastUpdated)
    {
        (bool success, bytes memory returnedData) = _adapter.staticcall(_payload);
        if (success) (price, lastUpdated) = abi.decode(returnedData, (uint256, uint256));
    }

    /// @dev Check if a price is stale
    /// @param _asset Asset address
    /// @param _lastUpdated Last updated timestamp
    /// @return isStale True if the price is stale
    function _isStale(address _asset, uint256 _lastUpdated) internal view returns (bool isStale) {
        isStale = block.timestamp - _lastUpdated > getPriceOracleStorage().staleness[_asset];
    }
}
