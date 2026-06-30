// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540Operator } from "../interfaces/IERC7540Operator.sol";

/// @title ERC7540Operator Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for ERC7540Operator
abstract contract ERC7540OperatorStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.ERC7540Operator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540OPERATOR_STORAGE_LOCATION =
        0x984a447e9a3f276a50a882321c9dcb50ab53cba0333a097400ab36b1a1a27200;

    /// @dev Get ERC7540Operator storage
    /// @return $ Storage pointer
    function getERC7540OperatorStorage() internal pure returns (IERC7540Operator.ERC7540OperatorStorage storage $) {
        assembly {
            $.slot := ERC7540OPERATOR_STORAGE_LOCATION
        }
    }
}
