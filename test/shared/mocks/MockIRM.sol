// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice No-op interest rate model satisfying the calls Stablecoin/Market make.
contract MockIRM {
    uint256 public updateCalls;

    function updateLiquidityRate() external {
        updateCalls++;
    }

    function liquidityIndex(address) external pure returns (uint256) {
        return 1e27;
    }

    function indices(address) external pure returns (uint256 liquidity, uint256 underwriter) {
        return (1e27, 1e27);
    }

    function underwriterIndex(address) external pure returns (uint256) {
        return 1e27;
    }

    function liquidationBonus() external pure returns (uint256) {
        return 0.02e27;
    }
}
