// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticNetworkMiddleware } from "../interfaces/ISymbioticNetworkMiddleware.sol";

/// @title Symbiotic Network Middleware Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Symbiotic Network Middleware
abstract contract SymbioticNetworkMiddlewareStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.NetworkMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SymbioticNetworkMiddlewareStorageLocation =
        0xb8e099bfced582503f4260023771d11f60bb84aadc54b7d0da79ce0abbf0e800;

    /// @dev Get Symbiotic Network Middleware storage
    /// @return $ Storage pointer
    function getSymbioticNetworkMiddlewareStorage()
        internal
        pure
        returns (ISymbioticNetworkMiddleware.SymbioticNetworkMiddlewareStorage storage $)
    {
        assembly {
            $.slot := SymbioticNetworkMiddlewareStorageLocation
        }
    }
}
