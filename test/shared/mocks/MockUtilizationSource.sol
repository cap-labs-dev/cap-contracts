// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

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

    /// @dev A supply pair whose ratio is the utilization the test asked for, so the averaged path
    /// and the spot path move off the same single knob
    function supplies() external view returns (uint256 credit, uint256 supply) {
        credit = supplyUtilization;
        supply = 1e27;
    }

    function utilization() external view returns (uint256) {
        return marketUtilization[address(this)];
    }
}
