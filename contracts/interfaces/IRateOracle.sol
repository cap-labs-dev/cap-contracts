// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IRateOracle {
    function marketRate(address asset) external view returns (uint256 rate);
    function benchmarkRate(address asset) external view returns (uint256 rate);
    function restakerRate(address agent) external view returns (uint256 rate);
    function setSource(address asset, address source) external;
    function setAdapter(address source, address adapter) external;
    function setRestakerRate(address agent, uint256 rate) external;
    function setBenchmarkRate(address asset, uint256 rate) external;
}
