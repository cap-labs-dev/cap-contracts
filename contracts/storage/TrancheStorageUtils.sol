// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ITranche } from "../interfaces/ITranche.sol";

/// @title Tranche Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for tranche
abstract contract TrancheStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Tranche")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TRANCHE_STORAGE_LOCATION =
        0x600efd5895765486edd6e9cb260406a857c463e520b9780b4c1610ed2b180f00;

    /// @dev Get tranche storage
    /// @return $ Storage pointer
    function getTrancheStorage() internal pure returns (ITranche.Storage storage $) {
        assembly {
            $.slot := TRANCHE_STORAGE_LOCATION
        }
    }
}
