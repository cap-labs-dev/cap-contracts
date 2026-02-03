// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IStabledrop } from "../interfaces/IStabledrop.sol";

/// @title Stabledrop Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for stabledrop
abstract contract StabledropStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Stabledrop")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StabledropStorageLocation =
        0x81f03370456276d7fadcc18cd18610013137ede5fbb50e4a608561ccb8f59800;

    /// @dev Get stabledrop storage
    /// @return $ Storage pointer
    function getStabledropStorage() internal pure returns (IStabledrop.StabledropStorage storage $) {
        assembly {
            $.slot := StabledropStorageLocation
        }
    }
}
