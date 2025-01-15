// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOracle } from "../interfaces/IOracle.sol";
import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";

/// @title Oracle for fetching interest rates
/// @author kexley, @capLabs
/// @notice Admin can set the minimum interest rates and the restaker interest rates.
contract RateOracle is AccessUpgradeable {
    /// @custom:storage-location erc7201:cap.storage.RateOracle
    struct RateOracleStorage {
        mapping(address => IOracle.OracleData) oracleData;
        mapping(address => uint256) benchmarkRate;
        mapping(address => uint256) restakerRate;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.RateOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RateOracleStorageLocation = 0xc2fe5bdef19b00667b17c16a6e885c9ed219a037de5cdf872528698fdc749f00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getRateOracleStorage() private pure returns (RateOracleStorage storage $) {
        assembly {
            $.slot := RateOracleStorageLocation
        }
    }

    /// @dev Set oracle data
    event SetRateOracleData(address asset, IOracle.OracleData data);

    /// @dev Set benchmark rate
    event SetBenchmarkRate(address asset, uint256 rate);

    /// @dev Set restaker rate
    event SetRestakerRate(address agent, uint256 rate);

    /// @dev Initialize the rate oracle
    /// @param _accessControl Access control address
    function __RateOracle_init(address _accessControl) internal onlyInitializing {
        __Access_init(_accessControl);
        __RateOracle_init_unchained();
    }

    /// @dev Initialize unchained
    function __RateOracle_init_unchained() internal onlyInitializing {}

    /// @notice Fetch the market rate for an asset being borrowed
    /// @param _asset Asset address
    /// @return rate Borrow interest rate
    function marketRate(address _asset) external returns (uint256 rate) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        IOracle.OracleData memory data = $.oracleData[_asset];
        rate = _getRate(data.adapter, data.payload);
    }

    /// @notice View the benchmark rate for an asset
    /// @param _asset Asset address
    /// @return rate Benchmark rate
    function benchmarkRate(address _asset) external view returns (uint256 rate) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        rate = $.benchmarkRate[_asset];
    }

    /// @notice View the restaker rate for an agent
    /// @param _agent Agent address
    /// @return rate Restaker rate
    function restakerRate(address _agent) external view returns (uint256 rate) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        rate = $.restakerRate[_agent];
    }

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address
    /// @return data Oracle data for an asset
    function rateOracleData(address _asset) external view returns (IOracle.OracleData memory data) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        data = $.oracleData[_asset];
    }

    /// @notice Set a rate source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setRateOracleData(address _asset, IOracle.OracleData calldata _oracleData)
        external
        checkAccess(this.setRateOracleData.selector)
    {
        RateOracleStorage storage $ = _getRateOracleStorage();
        $.oracleData[_asset] = _oracleData;
        emit SetRateOracleData(_asset, _oracleData);
    }

    /// @notice Update the minimum interest rate for an asset
    /// @param _asset Asset address
    /// @param _rate New interest rate
    function setBenchmarkRate(address _asset, uint256 _rate) external checkAccess(this.setBenchmarkRate.selector) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        $.benchmarkRate[_asset] = _rate;
        emit SetBenchmarkRate(_asset, _rate);
    }

    /// @notice Update the rate at which an agent accrues interest explicitly to pay restakers
    /// @param _agent Agent address
    /// @param _rate New interest rate
    function setRestakerRate(address _agent, uint256 _rate) external checkAccess(this.setRestakerRate.selector) {
        RateOracleStorage storage $ = _getRateOracleStorage();
        $.restakerRate[_agent] = _rate;
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
}
