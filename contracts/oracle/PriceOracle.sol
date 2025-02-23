// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { PriceOracleStorageUtils } from "../storage/PriceOracleStorageUtils.sol";

/// @title Oracle for fetching prices
/// @author kexley, @capLabs
/// @dev Payloads are stored on this contract and calculation logic is hosted on external libraries
contract PriceOracle is IPriceOracle, Access, PriceOracleStorageUtils {
    /// @dev Initialize the price oracle
    /// @param _accessControl Access control address
    function __PriceOracle_init(address _accessControl) internal onlyInitializing {
        __Access_init(_accessControl);
        __PriceOracle_init_unchained();
    }

    /// @dev Initialize unchained
    function __PriceOracle_init_unchained() internal onlyInitializing { }

    /// @notice Fetch the price for an asset
    /// @dev If initial price fetch fails then a backup source is used, never reverts
    /// @param _asset Asset address
    /// @return price Price of the asset
    /// @return lastUpdated Latest timestamp of the price
    function getPrice(address _asset) external view returns (uint256 price, uint256 lastUpdated) {
        PriceOracleStorage storage $ = getPriceOracleStorage();
        IOracle.OracleData memory data = $.oracleData[_asset];

        (price, lastUpdated) = _getPrice(data.adapter, data.payload);

        if (price == 0) {
            data = $.backupOracleData[_asset];
            (price, lastUpdated) = _getPrice(data.adapter, data.payload);
        }
    }

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address
    /// @return data Oracle data for an asset
    function priceOracleData(address _asset) external view returns (IOracle.OracleData memory data) {
        data = getPriceOracleStorage().oracleData[_asset];
    }

    /// @notice View the backup oracle data for an asset
    /// @param _asset Asset address
    /// @return data Backup oracle data for an asset
    function priceBackupOracleData(address _asset) external view returns (IOracle.OracleData memory data) {
        data = getPriceOracleStorage().backupOracleData[_asset];
    }

    /// @notice Set a price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setPriceOracleData(address _asset, IOracle.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceOracleData.selector)
    {
        getPriceOracleStorage().oracleData[_asset] = _oracleData;
        emit SetPriceOracleData(_asset, _oracleData);
    }

    /// @notice Set a backup price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setPriceBackupOracleData(address _asset, IOracle.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceBackupOracleData.selector)
    {
        getPriceOracleStorage().backupOracleData[_asset] = _oracleData;
        emit SetPriceBackupOracleData(_asset, _oracleData);
    }

    /// @dev Calculate price using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return price Calculated price
    function _getPrice(address _adapter, bytes memory _payload)
        private
        view
        returns (uint256 price, uint256 lastUpdated)
    {
        (bool success, bytes memory returnedData) = _adapter.staticcall(_payload);
        if (success) (price, lastUpdated) = abi.decode(returnedData, (uint256, uint256));
    }
}
