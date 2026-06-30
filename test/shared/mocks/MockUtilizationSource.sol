// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Mock that satisfies the calls InterestRateModel makes on the Stablecoin and the Lender.
/// @dev Lets tests drive the supply utilization (via utilizationRate) and per-market utilization
///      (via utilization) independently to exercise the rate/index math in isolation.
contract MockUtilizationSource {
    uint256 public supplyUtilization;
    mapping(bytes32 => uint256) public marketUtilization;

    function setSupplyUtilization(uint256 value) external {
        supplyUtilization = value;
    }

    function setMarketUtilization(bytes32 marketId, uint256 value) external {
        marketUtilization[marketId] = value;
    }

    /// @notice Stablecoin.utilizationRate() shape used by the supply-side IRM
    function utilizationRate() external view returns (uint256) {
        return supplyUtilization;
    }

    /// @notice Lender.utilization(marketId) shape used by the inverse IRM
    function utilization(bytes32 marketId) external view returns (uint256) {
        return marketUtilization[marketId];
    }
}
