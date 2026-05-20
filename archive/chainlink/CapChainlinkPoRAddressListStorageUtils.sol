// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapChainlinkPoRAddressList } from "../interfaces/ICapChainlinkPoRAddressList.sol";

/// @title Cap Chainlink PoR Address List Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for cap chainlink PoR address list
abstract contract CapChainlinkPoRAddressListStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapChainlinkPoRAddressList")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapChainlinkPoRAddressListStorageLocation =
        0x88c032b10d4ebec85eab0c277c6574cd969937e5c2fc658c01da3853dc183d00;

    /// @dev Get cap chainlink PoR address list storage
    /// @return $ Storage pointer
    function getCapChainlinkPoRAddressListStorage()
        internal
        pure
        returns (ICapChainlinkPoRAddressList.CapChainlinkPoRAddressListStorage storage $)
    {
        assembly {
            $.slot := CapChainlinkPoRAddressListStorageLocation
        }
    }
}
