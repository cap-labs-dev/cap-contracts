// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticAgentManager } from "../interfaces/ISymbioticAgentManager.sol";

/// @title Symbiotic Agent Manager Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for symbiotic agent manager
abstract contract SymbioticAgentManagerStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.SymbioticAgentManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SymbioticAgentManagerStorageLocation =
        0x45ef7bdbaab7eeba99f11d519f647755b44ea4868cedbefc54238484ef018200;

    /// @dev Get symbiotic agent manager storage
    /// @return $ Storage pointer
    function getSymbioticAgentManagerStorage()
        internal
        pure
        returns (ISymbioticAgentManager.SymbioticAgentManagerStorage storage $)
    {
        assembly {
            $.slot := SymbioticAgentManagerStorageLocation
        }
    }
}
