// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IEigenAgentManager } from "../interfaces/IEigenAgentManager.sol";

/// @title Eigen Agent Manager Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for eigen agent manager
abstract contract EigenAgentManagerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.EigenAgentManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EigenAgentManagerStorageLocation =
        0xfd8e9c49b112daf0453bd851da4ce96c57ae33d01ffa80f8eb965653c5ff1200;

    /// @dev Get eigen agent manager storage
    /// @return $ Storage pointer
    function getEigenAgentManagerStorage()
        internal
        pure
        returns (IEigenAgentManager.EigenAgentManagerStorage storage $)
    {
        assembly {
            $.slot := EigenAgentManagerStorageLocation
        }
    }
}
