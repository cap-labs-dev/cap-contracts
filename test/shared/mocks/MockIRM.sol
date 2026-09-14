// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice No-op interest rate model satisfying the calls Stablecoin/Market make.
contract MockIRM {
    uint256 public updateCalls;

    function updateLiquidityRate() external {
        updateCalls++;
    }

    function liquidityIndex() external pure returns (uint256) {
        return 1e27;
    }

    function underwriterIndex(address) external pure returns (uint256) {
        return 1e27;
    }

    function liquidationBonus() external pure returns (uint256) {
        return 0.02e27;
    }
}
