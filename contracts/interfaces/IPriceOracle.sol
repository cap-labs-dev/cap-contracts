// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracleTypes } from "./IOracleTypes.sol";

/// @title IPriceOracle
/// @author kexley, Cap Labs
/// @notice Interface for the price oracle
interface IPriceOracle is IOracleTypes {
    /// @notice Storage for the price oracle
    /// @param oracleData Oracle data for each asset
    /// @param backupOracleData Backup oracle data for each asset
    /// @param staleness Staleness period for each asset
    struct PriceOracleStorage {
        mapping(address => IOracleTypes.OracleData) oracleData;
        mapping(address => IOracleTypes.OracleData) backupOracleData;
        mapping(address => uint256) staleness;
    }

    /// @dev Set oracle data
    event SetPriceOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set backup oracle data
    event SetPriceBackupOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set the staleness period for asset prices
    event SetStaleness(address asset, uint256 staleness);

    /// @dev Price error
    error PriceError(address asset);

    /// @notice Set the oracle data for an asset
    /// @param _asset Asset address to set oracle data for
    /// @param _oracleData Oracle data configuration to set for the asset
    function setPriceOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Set the backup oracle data for an asset
    /// @param _asset Asset address to set backup oracle data for
    /// @param _oracleData Backup oracle data configuration to set for the asset
    function setPriceBackupOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Set the staleness period for asset prices
    /// @param _asset Asset address to set staleness period for
    /// @param _staleness Staleness period in seconds for asset prices
    function setStaleness(address _asset, uint256 _staleness) external;

    /// @notice Get the price for an asset
    /// @param _asset Asset address to get price for
    /// @return price Current price of the asset
    /// @return lastUpdated Last updated timestamp
    function getPrice(address _asset) external view returns (uint256 price, uint256 lastUpdated);

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address to get oracle data for
    /// @return data Oracle data configuration for the asset
    function priceOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);

    /// @notice View the backup oracle data for an asset
    /// @param _asset Asset address to get backup oracle data for
    /// @return data Backup oracle data configuration for the asset
    function priceBackupOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);

    /// @notice View the staleness period for asset prices
    /// @param _asset Asset address to get staleness period for
    /// @return assetStaleness Staleness period in seconds for asset prices
    function staleness(address _asset) external view returns (uint256 assetStaleness);
}
