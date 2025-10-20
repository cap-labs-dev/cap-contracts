// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IEigenServiceManager } from "../interfaces/IEigenServiceManager.sol";

/// @title EigenServiceManager Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for EigenServiceManager
abstract contract EigenServiceManagerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.EigenServiceManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EigenServiceManagerStorageLocation =
        0x9813e4033b5f31d05a061ad9d06fb8352756b0443d3cc09baeca467c0811ef00;

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
