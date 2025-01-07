// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IRegistry } from "../interfaces/IRegistry.sol";
import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";

/// @title Oracle for fetching prices
/// @author kexley, @capLabs
contract PriceOracle is UUPSUpgradeable {

    /// @notice Registry address
    address public registry;

    /// @notice Source of an asset's price
    mapping(address => address) public source;

    /// @notice Backup source of an asset's price
    mapping(address => address) public backupSource;

    /// @notice Adapter for calculating price
    mapping(address => address) public adapter;

    /// @dev Not authorized to call
    error NotAuth();

    /// @dev No adapter will result in failed calculations
    error NoAdapter();

    /// @dev Only authorized addresses can call these functions
    modifier onlyAuth {
        if (msg.sender != IRegistry(registry).assetManager()) revert NotAuth();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle with the registry address
    /// @param _registry Registry address
    function initialize(address _registry) external initializer {
        registry = _registry;
    }

    /// @notice Fetch the price for an asset
    /// @param _asset Asset address
    /// @return price Price of the asset
    function getPrice(address _asset) external view returns (uint256 price) {
        address sourceAddress = source[_asset];
        address adapterAddress = adapter[sourceAddress];

        price = IOracleAdapter(adapterAddress).price(sourceAddress, _asset);

        if (price == 0) {
            sourceAddress = backupSource[_asset];
            adapterAddress = adapter[sourceAddress];

            price = IOracleAdapter(adapterAddress).price(sourceAddress, _asset);
        }
    }

    /// @notice Set a price source for an asset
    /// @param _asset Asset address
    /// @param _source Source of an asset price
    function setSource(address _asset, address _source) external onlyAuth {
        if (adapter[_source] == address(0)) revert NoAdapter();
        source[_asset] = _source;
    }

    /// @notice Set a backup price source for an asset
    /// @param _asset Asset address
    /// @param _source Backup source of an asset price
    function setBackupSource(address _asset, address _source) external onlyAuth {
        if (adapter[_source] == address(0)) revert NoAdapter();
        backupSource[_asset] = _source;
    }

    /// @notice Set an adapter for a price source
    /// @param _source Source of an asset price
    /// @param _adapter Adapter for calculating the price
    function setAdapter(address _source, address _adapter) external onlyAuth {
        if (_adapter == address(0)) revert NoAdapter();
        adapter[_source] = _adapter;
    }

    function _authorizeUpgrade(address) internal override {}
}
