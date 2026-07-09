// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IMarket } from "../interfaces/IMarket.sol";

/// @title Market Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Market
abstract contract MarketStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Market")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKET_STORAGE_LOCATION =
        0xbb08105a09d87dbda58bb8040836744d08c16a52e5cfed46ffdfe51c9f4b6e00;

    /// @dev Get Market storage
    /// @return $ Storage pointer
    function getMarketStorage() internal pure returns (IMarket.Storage storage $) {
        assembly {
            $.slot := MARKET_STORAGE_LOCATION
        }
    }
}
