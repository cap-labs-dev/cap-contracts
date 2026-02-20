// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICCAToken } from "../interfaces/ICCAToken.sol";

/// @title CCA Token Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for CCA token
abstract contract CCATokenStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CCAToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CCATokenStorageLocation =
        0xa04c1cb38e42306cf4ff9cc4b0523ffa6da08328d6404f7e1cfc0cc7248f0700;

    /// @dev Get CCA token storage
    /// @return $ Storage pointer
    function getCCATokenStorage() internal pure returns (ICCAToken.CCATokenStorage storage $) {
        assembly {
            $.slot := CCATokenStorageLocation
        }
    }
}
