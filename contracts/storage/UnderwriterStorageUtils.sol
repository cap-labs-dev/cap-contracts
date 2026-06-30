// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IUnderwriter } from "../interfaces/IUnderwriter.sol";

/// @title Underwriter Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for underwriter
abstract contract UnderwriterStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Underwriter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UNDERWRITER_STORAGE_LOCATION =
        0xace93d61a541ca54a7e0a8055fc39b59e114b139dcb1d098e28f80405e592c00;

    /// @dev Get underwriter storage
    /// @return $ Storage pointer
    function getUnderwriterStorage() internal pure returns (IUnderwriter.Storage storage $) {
        assembly {
            $.slot := UNDERWRITER_STORAGE_LOCATION
        }
    }
}
