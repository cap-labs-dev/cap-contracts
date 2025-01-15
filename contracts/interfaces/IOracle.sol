// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    struct OracleData {
        address adapter;
        bytes payload;
    }

    function getPrice(address asset) external view returns (uint256 price);
    function priceOracleData(address asset) external view returns (OracleData memory data);
    function priceBackupOracleData(address asset) external view returns (OracleData memory data);
    function setPriceOracleData(address asset, OracleData calldata oracleData) external;
    function setPriceBackupOracleData(address asset, OracleData calldata oracleData) external;

    function marketRate(address asset) external returns (uint256 rate);
    function benchmarkRate(address asset) external view returns (uint256 rate);
    function restakerRate(address agent) external view returns (uint256 rate);
    function rateOracleData(address asset) external view returns (OracleData memory data);
    function setRateOracleData(address asset, OracleData calldata oracleData) external;
    function setBenchmarkRate(address asset, uint256 rate) external;
    function setRestakerRate(address agent, uint256 rate) external;
}
