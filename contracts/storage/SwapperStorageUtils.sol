// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISwapper } from "../interfaces/ISwapper.sol";

/// @title Swapper Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for swapper
abstract contract SwapperStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Swapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SwapperStorageLocation =
        0x5ccbea696b3fd95cb08bf7e53a65fba07598658ec42cdf1fca09e0c714622a00;

    /// @dev Get swapper storage
    /// @return $ Storage pointer
    function getSwapperStorage() internal pure returns (ISwapper.SwapperStorage storage $) {
        assembly {
            $.slot := SwapperStorageLocation
        }
    }
}
