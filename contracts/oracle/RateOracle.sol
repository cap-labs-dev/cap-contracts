// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { IOracleTypes } from "../interfaces/IOracleTypes.sol";
import { IRateOracle } from "../interfaces/IRateOracle.sol";
import { RateOracleStorageUtils } from "../storage/RateOracleStorageUtils.sol";

/// @title Rate Oracle
/// @author kexley, Cap Labs
/// @notice Admin can set the minimum interest rates and the restaker interest rates
abstract contract RateOracle is IRateOracle, Access, RateOracleStorageUtils {
    /// @inheritdoc IRateOracle
    function setMarketOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData)
        external
        checkAccess(this.setMarketOracleData.selector)
    {
        getRateOracleStorage().marketOracleData[_asset] = _oracleData;
        emit SetMarketOracleData(_asset, _oracleData);
    }

    /// @inheritdoc IRateOracle
    function setUtilizationOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData)
        external
        checkAccess(this.setUtilizationOracleData.selector)
    {
        getRateOracleStorage().utilizationOracleData[_asset] = _oracleData;
        emit SetUtilizationOracleData(_asset, _oracleData);
    }

    /// @inheritdoc IRateOracle
    function setBenchmarkRate(address _asset, uint256 _rate) external checkAccess(this.setBenchmarkRate.selector) {
        getRateOracleStorage().benchmarkRate[_asset] = _rate;
        emit SetBenchmarkRate(_asset, _rate);
    }

    /// @inheritdoc IRateOracle
    function setRestakerRate(address _agent, uint256 _rate) external checkAccess(this.setRestakerRate.selector) {
        getRateOracleStorage().restakerRate[_agent] = _rate;
        emit SetRestakerRate(_agent, _rate);
    }

    /// @inheritdoc IRateOracle
    function marketRate(address _asset) external returns (uint256 rate) {
        IOracleTypes.OracleData memory data = getRateOracleStorage().marketOracleData[_asset];
        rate = _getRate(data.adapter, data.payload);
    }

    /// @inheritdoc IRateOracle
    function utilizationRate(address _asset) external returns (uint256 rate) {
        IOracleTypes.OracleData memory data = getRateOracleStorage().utilizationOracleData[_asset];
        rate = _getRate(data.adapter, data.payload);
    }

    /// @inheritdoc IRateOracle
    function benchmarkRate(address _asset) external view returns (uint256 rate) {
        rate = getRateOracleStorage().benchmarkRate[_asset];
    }

    /// @inheritdoc IRateOracle
    function restakerRate(address _agent) external view returns (uint256 rate) {
        rate = getRateOracleStorage().restakerRate[_agent];
    }

    /// @inheritdoc IRateOracle
    function marketOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data) {
        data = getRateOracleStorage().marketOracleData[_asset];
    }

    /// @inheritdoc IRateOracle
    function utilizationOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data) {
        data = getRateOracleStorage().utilizationOracleData[_asset];
    }

    /// @dev Initialize the rate oracle
    /// @param _accessControl Access control address
    function __RateOracle_init(address _accessControl) internal onlyInitializing {
        __Access_init(_accessControl);
        __RateOracle_init_unchained();
    }

    /// @dev Initialize unchained is empty
    function __RateOracle_init_unchained() internal onlyInitializing { }

    /// @dev Calculate rate using an adapter and payload but do not revert on errors
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @return rate Calculated rate
    function _getRate(address _adapter, bytes memory _payload) private returns (uint256 rate) {
        (bool success, bytes memory returnedData) = _adapter.call(_payload);
        if (success) rate = abi.decode(returnedData, (uint256));
    }
}
