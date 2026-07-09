// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Mock that satisfies the calls InterestRateModel makes on Stablecoin and Market.
contract MockUtilizationSource {
    uint256 public supplyUtilization;
    mapping(address => uint256) public marketUtilization;

    function setSupplyUtilization(uint256 value) external {
        supplyUtilization = value;
    }

    function setMarketUtilization(address market, uint256 value) external {
        marketUtilization[market] = value;
    }

    function utilizationRate() external view returns (uint256) {
        return supplyUtilization;
    }

    function utilization() external view returns (uint256) {
        return marketUtilization[address(this)];
    }
}
