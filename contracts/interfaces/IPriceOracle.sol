// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256 price);
    function setSource(address asset, address source) external;
    function setBackupSource(address asset, address source) external;
    function setAdapter(address source, address adapter) external;
}