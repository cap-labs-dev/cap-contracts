// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Market Rate Adapter
/// @author weso, Cap Labs
/// @notice Market rate is hardcoded to 0
library MarketRateAdapter {
    /// @notice Returns the market rate for an asset
    /// @return latestAnswer Latest borrow rate for the asset
    function rate() external view returns (uint256 latestAnswer) {
        return 0;
    }
}
