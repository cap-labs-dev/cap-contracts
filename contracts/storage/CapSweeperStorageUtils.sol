// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapSweeper } from "../interfaces/ICapSweeper.sol";

/// @title Cap Sweeper Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for cap sweeper
abstract contract CapSweeperStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapSweeper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapSweeperStorageLocation =
        0x1d4964060d7172160e190526b28e383cc35e2a436259d2fbbdd50d48022d7100;

    /// @dev Get cap sweeper storage
    /// @return $ Storage pointer
    function getCapSweeperStorage() internal pure returns (ICapSweeper.CapSweeperStorage storage $) {
        assembly {
            $.slot := CapSweeperStorageLocation
        }
    }
}
