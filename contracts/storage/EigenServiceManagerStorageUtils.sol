// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IEigenServiceManager } from "../interfaces/IEigenServiceManager.sol";

/// @title EigenServiceManager Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for EigenServiceManager
abstract contract EigenServiceManagerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.EigenServiceManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EigenServiceManagerStorageLocation =
        0x54b6f5557fb44acf280f59f684357ef1d216e247bba38a36a74ec93b2377e200;

    /// @dev Get EigenServiceManager storage
    /// @return $ Storage pointer
    function getEigenServiceManagerStorage()
        internal
        pure
        returns (IEigenServiceManager.EigenServiceManagerStorage storage $)
    {
        assembly {
            $.slot := EigenServiceManagerStorageLocation
        }
    }
}
