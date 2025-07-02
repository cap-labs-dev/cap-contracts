// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticNetwork } from "../interfaces/ISymbioticNetwork.sol";

/// @title Symbiotic Network Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Symbiotic Network
abstract contract SymbioticNetworkStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Network")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SymbioticNetworkStorageLocation =
        0xec23e17a5ca56acc6967467b8c4a73cf6149bcd343f3f3cbe7c4e19c4d822b00;

    /// @dev Get Symbiotic Network storage
    /// @return $ Storage pointer
    function getSymbioticNetworkStorage() internal pure returns (ISymbioticNetwork.SymbioticNetworkStorage storage $) {
        assembly {
            $.slot := SymbioticNetworkStorageLocation
        }
    }
}
