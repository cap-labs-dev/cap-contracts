// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";

/// @title Oracle for fetching prices
/// @author kexley, @capLabs
/// @dev Payloads are stored on this contract and calculation logic is hosted on external libraries
contract PriceOracle is UUPSUpgradeable {
    /// @notice Price oracle admin role
    bytes32 public constant PRICE_ORACLE_ADMIN = keccak256("PRICE_ORACLE_ADMIN");

    /// @dev Oracle data for fetching prices
    /// @param adapter Adapter address containing logic
    /// @param payload Encoded data for calculating prices
    struct OracleData {
        address adapter;
        bytes payload;
    }

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @notice Data used to calculate an asset's price
    mapping(address => OracleData) public oracleData;

    /// @notice Backup data used to calculate an asset's price
    mapping(address => OracleData) public backupOracleData;

    /// @dev No adapter will result in failed calculations
    error NoAdapter();

    /// @dev Set oracle data
    event SetOracleData(address asset, OracleData data);

    /// @dev Set backup oracle data
    event SetBackupOracleData(address asset, OracleData data);

    /// @dev Only authorized addresses can call these functions
    modifier onlyAdmin {
        _onlyAdmin();
        _;
    }

    /// @dev Reverts if the caller is not admin
    function _onlyAdmin() private view {
        addressProvider.checkRole(PRICE_ORACLE_ADMIN, msg.sender);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle with the address provider
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
    }

    /// @notice Fetch the price for an asset
    /// @dev If initial price fetch fails then a backup source is used, never reverts
    /// @param _asset Asset address
    /// @return price Price of the asset
    function getPrice(address _asset) external returns (uint256 price) {
        OracleData memory data = oracleData[_asset];

        price = _getPrice(data.adapter, data.payload);
        
        if (price == 0) {
            data = backupOracleData[_asset];
            price = _getPrice(data.adapter, data.payload);
        }
    }

    /// @notice Set a price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setOracleData(address _asset, OracleData calldata _oracleData) external onlyAdmin {
        if (_oracleData.adapter == address(0)) revert NoAdapter();
        oracleData[_asset] = _oracleData;
        emit SetOracleData(_asset, _oracleData);
    }

    /// @notice Set a backup price source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setBackupOracleData(address _asset, OracleData calldata _oracleData) external onlyAdmin {
        if (_oracleData.adapter == address(0)) revert NoAdapter();
        backupOracleData[_asset] = _oracleData;
        emit SetBackupOracleData(_asset, _oracleData);
    }

    /// @dev Calculate price using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return price Calculated price
    function _getPrice(address _adapter, bytes memory _payload) private returns (uint256 price) {
        (bool success, bytes memory returnedData) = _adapter.call(_payload);
        if (success) price = abi.decode(returnedData, (uint256));
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
