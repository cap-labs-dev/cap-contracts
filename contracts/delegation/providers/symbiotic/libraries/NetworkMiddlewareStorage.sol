// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Network Middleware storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library NetworkMiddlewareStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.NetworkMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NetworkMiddlewareStorageLocation = 0xb8e099bfced582503f4260023771d11f60bb84aadc54b7d0da79ce0abbf0e800;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.NetworkMiddlewareStorage storage $) {
        assembly {
            $.slot := NetworkMiddlewareStorageLocation
        }
    }
}
