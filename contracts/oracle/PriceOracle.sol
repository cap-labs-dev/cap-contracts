// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOracle } from "../interfaces/IOracle.sol";
import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";

/// @title Oracle for fetching prices
/// @author kexley, @capLabs
/// @dev Payloads are stored on this contract and calculation logic is hosted on external libraries
contract PriceOracle is AccessUpgradeable {
    /// @custom:storage-location erc7201:cap.storage.PriceOracle
    struct PriceOracleStorage {
        mapping(address => IOracle.OracleData) oracleData;
        mapping(address => IOracle.OracleData) backupOracleData;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.PriceOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PriceOracleStorageLocation = 0x02a142d837c166bd77dc34adb0a38ff11e81f2f3e8008e975ef32f5fb877ac00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getPriceOracleStorage() private pure returns (PriceOracleStorage storage $) {
        assembly {
            $.slot := PriceOracleStorageLocation
        }
    }

    /// @dev Set oracle data
    event SetPriceOracleData(address asset, IOracle.OracleData data);

    /// @dev Set backup oracle data
    event SetPriceBackupOracleData(address asset, IOracle.OracleData data);

    /// @dev Initialize the price oracle
    /// @param _accessControl Access control address
    function __PriceOracle_init(address _accessControl) internal onlyInitializing {
        __Access_init(_accessControl);
        __PriceOracle_init_unchained();
    }

    /// @dev Initialize unchained
    function __PriceOracle_init_unchained() internal onlyInitializing {}

    /// @notice Fetch the price for an asset
    /// @dev If initial price fetch fails then a backup source is used, never reverts
    /// @param _asset Asset address
    /// @return price Price of the asset
    function getPrice(address _asset) external returns (uint256 price) {
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        IOracle.OracleData memory data = $.oracleData[_asset];

        price = _getPrice(data.adapter, data.payload);

        if (price == 0) {
            data = $.backupOracleData[_asset];
            price = _getPrice(data.adapter, data.payload);
        }
    }

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address
    /// @return data Oracle data for an asset
    function priceOracleData(address _asset) external view returns (IOracle.OracleData memory data) {
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        data = $.oracleData[_asset];
    }

    /// @notice View the backup oracle data for an asset
    /// @param _asset Asset address
    /// @return data Backup oracle data for an asset
    function priceBackupOracleData(address _asset) external view returns (IOracle.OracleData memory data) {
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        data = $.backupOracleData[_asset];
    }

    /// @notice Set a price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setPriceOracleData(address _asset, IOracle.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceOracleData.selector)
    {
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        $.oracleData[_asset] = _oracleData;
        emit SetPriceOracleData(_asset, _oracleData);
    }

    /// @notice Set a backup price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setPriceBackupOracleData(address _asset, IOracle.OracleData calldata _oracleData)
        external
        checkAccess(this.setPriceBackupOracleData.selector)
    {
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        $.backupOracleData[_asset] = _oracleData;
        emit SetPriceBackupOracleData(_asset, _oracleData);
    }

    /// @dev Calculate price using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return price Calculated price
    function _getPrice(address _adapter, bytes memory _payload) private returns (uint256 price) {
        (bool success, bytes memory returnedData) = _adapter.call(_payload);
        if (success) price = abi.decode(returnedData, (uint256));
    }
}
