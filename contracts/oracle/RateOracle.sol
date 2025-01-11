// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";

/// @title Oracle for fetching interest rates
/// @author kexley, @capLabs
/// @notice Admin can set the minimum interest rates and the restaker interest rates.
contract RateOracle is UUPSUpgradeable, AccessUpgradeable {
    /// @dev Rate data for fetching rate
    /// @param adapter Adapter address containing logic
    /// @param payload Encoded data for calculating rates
    struct OracleData {
        address adapter;
        bytes payload;
    }

    /// @notice Data used to calculate an asset's rate
    mapping(address => OracleData) public oracleData;

    /// @notice Minimum borrow rate of an asset
    mapping(address => uint256) public benchmarkRate;

    /// @notice Interest rate per agent to be paid to restakers
    mapping(address => uint256) public restakerRate;

    /// @dev No adapter will result in failed calculations
    error NoAdapter();

    /// @dev Set oracle data
    event SetOracleData(address asset, OracleData data);

    /// @dev Set benchmark rate
    event SetBenchmarkRate(address asset, uint256 rate);

    /// @dev Set restaker rate
    event SetRestakerRate(address agent, uint256 rate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle with the access control
    /// @param _accessControl Access control
    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
    }

    /// @notice Fetch the market rate for an asset being borrowed
    /// @param _asset Asset address
    /// @return rate Borrow interest rate
    function marketRate(address _asset) external returns (uint256 rate) {
        OracleData memory data = oracleData[_asset];
        rate = _getRate(data.adapter, data.payload);
    }

    /// @notice Set a rate source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setOracleData(address _asset, OracleData calldata _oracleData)
        external
        checkAccess(this.setOracleData.selector)
    {
        if (_oracleData.adapter == address(0)) revert NoAdapter();
        oracleData[_asset] = _oracleData;
        emit SetOracleData(_asset, _oracleData);
    }

    /// @notice Update the minimum interest rate for an asset
    /// @param _asset Asset address
    /// @param _rate New interest rate
    function setBenchmarkRate(address _asset, uint256 _rate) external checkAccess(this.setBenchmarkRate.selector) {
        benchmarkRate[_asset] = _rate;
        emit SetBenchmarkRate(_asset, _rate);
    }

    /// @notice Update the rate at which an agent accrues interest explicitly to pay restakers
    /// @param _agent Agent address
    /// @param _rate New interest rate
    function setRestakerRate(address _agent, uint256 _rate) external checkAccess(this.setRestakerRate.selector) {
        restakerRate[_agent] = _rate;
        emit SetRestakerRate(_agent, _rate);
    }

    /// @dev Calculate rate using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return rate Calculated rate
    function _getRate(address _adapter, bytes memory _payload) private returns (uint256 rate) {
        (bool success, bytes memory returnedData) = _adapter.call(_payload);
        if (success) rate = abi.decode(returnedData, (uint256));
    }

    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
