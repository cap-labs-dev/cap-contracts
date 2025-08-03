// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ISymbioticOperator } from "../interfaces/ISymbioticOperator.sol";

abstract contract SymbioticOperatorStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.SymbioticOperator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SymbioticOperatorStorageLocation =
        0xc9e21d9312c13af5985059cb836687c68355447ab57ae880f3845d44a819b200;

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
