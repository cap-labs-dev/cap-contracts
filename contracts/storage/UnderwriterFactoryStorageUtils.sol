// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IUnderwriterFactory } from "../interfaces/IUnderwriterFactory.sol";

/// @title Underwriter Factory Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for UnderwriterFactory
abstract contract UnderwriterFactoryStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.UnderwriterFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UNDERWRITER_FACTORY_STORAGE_LOCATION =
        0x322ef978754e795b04e6d54a8985ca261ff9c85d5780bfb24c57bea5bcfc8700;

    /// @dev Get underwriter factory storage
    /// @return $ Storage pointer
    function getUnderwriterFactoryStorage() internal pure returns (IUnderwriterFactory.Storage storage $) {
        assembly {
            $.slot := UNDERWRITER_FACTORY_STORAGE_LOCATION
        }
    }
}
