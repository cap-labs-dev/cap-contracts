// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapUSDRateProvider } from "../interfaces/ICapUSDRateProvider.sol";

abstract contract CapUSDRateProviderStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapUSDRateProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapUSDRateProviderStorageLocation =
        0xec23e17a5ca56acc6967467b8c4a73cf6149bcd343f3f3cbe7c4e19c4d822b00;

    /// @dev Get Cap USDRate Provider storage
    /// @return $ Storage pointer
    function getCapUSDRateProviderStorage()
        internal
        pure
        returns (ICapUSDRateProvider.CapUSDRateProviderStorage storage $)
    {
        assembly {
            $.slot := CapUSDRateProviderStorageLocation
        }
    }
}
