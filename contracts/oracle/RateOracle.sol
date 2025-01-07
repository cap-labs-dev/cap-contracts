// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IRegistry } from "../interfaces/IRegistry.sol";
import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";

/// @title Oracle for fetching interest rates
/// @author kexley, @capLabs
/// @notice Admin can set the minimum interest rates and the restaker interest rates.
contract RateOracle is UUPSUpgradeable {

    /// @notice Registry address
    address public registry;

    /// @notice Source of an asset's borrowing rate
    mapping(address => address) public source;

    /// @notice Adapter for calculating borrow rate
    mapping(address => address) public adapter;

    /// @notice Minimum borrow rate of an asset
    mapping(address => uint256) public benchmarkRate;

    /// @notice Interest rate per agent to be paid to restakers
    mapping(address => uint256) public restakerRate;

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

    /// @notice Fetch the market rate for an asset being borrowed
    /// @param _asset Asset address
    /// @return rate Borrow interest rate
    function marketRate(address _asset) external view returns (uint256 rate) {
        address sourceAddress = source[_asset];
        address adapterAddress = adapter[sourceAddress];

        rate = IOracleAdapter(adapterAddress).rate(sourceAddress, _asset);
    }

    /// @notice Set a rate source for an asset
    /// @param _asset Asset address
    /// @param _source Source of an asset interest rate
    function setSource(address _asset, address _source) external onlyAuth {
        if (adapter[_source] == address(0)) revert NoAdapter();
        source[_asset] = _source;
    }

    /// @notice Set an adapter for a rate source
    /// @param _source Source of an asset interest rate
    /// @param _adapter Adapter for calculating the rate
    function setAdapter(address _source, address _adapter) external onlyAuth {
        if (_adapter == address(0)) revert NoAdapter();
        adapter[_source] = _adapter;
    }

    /// @notice Update the rate at which an agent accrues interest explicitly to pay restakers
    /// @param _agent Agent address
    /// @param _rate New interest rate
    function setRestakerRate(address _agent, uint256 _rate) external onlyAuth {
        restakerRate[_agent] = _rate;
    }

    /// @notice Update the minimum interest rate for an asset
    /// @param _asset Asset address
    /// @param _rate New interest rate
    function setBenchmarkRate(address _asset, uint256 _rate) external onlyAuth {
        benchmarkRate[_asset] = _rate;
    }

    function _authorizeUpgrade(address) internal override {}
}
