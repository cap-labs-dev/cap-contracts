// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./types/DataTypes.sol";

/// @title FractionalReserve storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library FractionalReserveStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.FractionalReserve")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FractionalReserveStorageLocation = 0x5c48f30a22a9811126b69b5adcaabfc5ae0a83b6493e1b31e09dc579923ad100;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (DataTypes.FractionalReserveStorage storage $) {
        assembly {
            $.slot := FractionalReserveStorageLocation
        }
    }
}
