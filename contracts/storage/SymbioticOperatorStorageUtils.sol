// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticOperator } from "../interfaces/ISymbioticOperator.sol";

abstract contract SymbioticOperatorStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.SymbioticOperator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SymbioticOperatorStorageLocation =
        0x54b6f5557fb44acf280f59f684357ef1d216e247bba38a36a74ec93b2377e200;

    /// @dev Get SymbioticOperator storage
    /// @return $ Storage pointer
    function getSymbioticOperatorStorage()
        internal
        pure
        returns (ISymbioticOperator.SymbioticOperatorStorage storage $)
    {
        assembly {
            $.slot := SymbioticOperatorStorageLocation
        }
    }
}
