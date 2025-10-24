// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IFixedPriceOracle } from "../../interfaces/IFixedPriceOracle.sol";

/// @title Fixed Price Oracle
/// @author kexley, Cap Labs
/// @notice Price is fixed at 1 USD (8 decimals)
contract FixedPriceOracle is IFixedPriceOracle {
    /// @inheritdoc IFixedPriceOracle
    function price() external view returns (uint256 fixedPrice, uint256 lastUpdated) {
        fixedPrice = 1e8; // 1 USD
        lastUpdated = block.timestamp;
    }
}
