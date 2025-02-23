// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "./IOracle.sol";

interface IPriceOracle {
    /// @notice Storage for the price oracle
    struct PriceOracleStorage {
        mapping(address => IOracle.OracleData) oracleData;
        mapping(address => IOracle.OracleData) backupOracleData;
    }

    /// @notice Get the price for an asset
    /// @param _asset Asset address to get price for
    /// @return price Current price of the asset
    /// @return lastUpdated Latest timestamp of the price
    function getPrice(address _asset) external view returns (uint256 price, uint256 lastUpdated);

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address to get oracle data for
    /// @return data Oracle data configuration for the asset
    function priceOracleData(address _asset) external view returns (IOracle.OracleData memory data);

    /// @notice View the backup oracle data for an asset
    /// @param _asset Asset address to get backup oracle data for
    /// @return data Backup oracle data configuration for the asset
    function priceBackupOracleData(address _asset) external view returns (IOracle.OracleData memory data);

    /// @notice Set the oracle data for an asset
    /// @notice Set the oracle data for an asset
    /// @param _asset Asset address to set oracle data for
    /// @param _oracleData Oracle data configuration to set for the asset
    function setPriceOracleData(address _asset, IOracle.OracleData calldata _oracleData) external;

    /// @notice Set the backup oracle data for an asset
    /// @param _asset Asset address to set backup oracle data for
    /// @param _oracleData Backup oracle data configuration to set for the asset
    function setPriceBackupOracleData(address _asset, IOracle.OracleData calldata _oracleData) external;

    /// @dev Set oracle data
    event SetPriceOracleData(address asset, IOracle.OracleData data);

    /// @dev Set backup oracle data
    event SetPriceBackupOracleData(address asset, IOracle.OracleData data);
}
