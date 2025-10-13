// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapLiquidator } from "../interfaces/ICapLiquidator.sol";

/// @title Cap Liquidator Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for cap liquidator
abstract contract CapLiquidatorStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapLiquidator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapLiquidatorStorageLocation =
        0xfcaeb3715ba096b5adee3f3404716ca7dd137705166f779f55e9930412188d00;

    /// @dev Get cap liquidator storage
    /// @return $ Storage pointer
    function getCapLiquidatorStorage() internal pure returns (ICapLiquidator.CapLiquidatorStorage storage $) {
        assembly {
            $.slot := CapLiquidatorStorageLocation
        }
    }
}
