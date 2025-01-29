// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title Delegation storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library DelegationStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Delegation")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DelegationStorageLocation = 0x54b6f5557fb44acf280f59f684357ef1d216e247bba38a36a74ec93b2377e200;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.DelegationStorage storage $) {
        assembly {
            $.slot := DelegationStorageLocation
        }
    }
}
