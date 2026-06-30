// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IStablecoin } from "../interfaces/IStablecoin.sol";

/// @title Stablecoin Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for cUSD
abstract contract StablecoinStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Stablecoin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STABLECOIN_STORAGE_LOCATION =
        0xb4d0fed9b23569fd5a9cf7d30ca71c56f00945179421def3b814fede1a2b4000;

    /// @dev Get Stablecoin storage
    /// @return $ Storage pointer
    function getStablecoinStorage() internal pure returns (IStablecoin.Storage storage $) {
        assembly {
            $.slot := STABLECOIN_STORAGE_LOCATION
        }
    }
}
