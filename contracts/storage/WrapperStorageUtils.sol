// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IWrapper } from "../interfaces/IWrapper.sol";

/// @title WrapperStorageUtils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Wrapper contract
abstract contract WrapperStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Wrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant WrapperStorageLocation = 0xcefd3d92422fccee73a9741c1e2fdb5ab7eafa1253faeebee5a888e84df9f200;

    /// @notice Get wrapper storage
    /// @return $ Storage pointer
    function getWrapperStorage() internal pure returns (IWrapper.WrapperStorage storage $) {
        assembly {
            $.slot := WrapperStorageLocation
        }
    }
}
