// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IEigenOperator } from "../interfaces/IEigenOperator.sol";

/// @title EigenOperator Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for EigenOperator
abstract contract EigenOperatorStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.EigenOperator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EigenOperatorStorageLocation =
        0x960b4b43d7da1001f900c7ba4e78a0a350e1c730ee58306f13b7c137edf1ee00;

    /// @dev Get EigenOperator storage
    /// @return $ Storage pointer
    function getEigenOperatorStorage() internal pure returns (IEigenOperator.EigenOperatorStorage storage $) {
        assembly {
            $.slot := EigenOperatorStorageLocation
        }
    }
}
