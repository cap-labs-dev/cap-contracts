// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title StakedCap storage pointer
/// @author kexley, @capLabs
library StakedCapStorage {
    /// @custom:storage-location erc7201:cap.storage.StakedCap
    struct StakedCapStorageStruct {
        uint256 storedTotal;
        uint256 totalLocked;
        uint256 lastNotify;
        uint256 lockDuration;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.StakedCap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StakedCapStorageLocation = 0xc3a6ec7b30f1d79063d00dcbb5942b226b77fe48a28f1a19018e7d1f70fd7600;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (StakedCapStorageStruct storage $) {
        assembly {
            $.slot := StakedCapStorageLocation
        }
    }
}
