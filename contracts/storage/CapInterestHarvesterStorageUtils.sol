// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapInterestHarvester } from "../interfaces/ICapInterestHarvester.sol";

/// @title Cap Interest Harvester Storage Utils
/// @author weso, Cap Labs
/// @notice Storage utilities for cap interest harvester
abstract contract CapInterestHarvesterStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.CapInterestHarvester")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CapInterestHarvesterStorageLocation =
        0xe6deaaba5d3c1b5422eff673d45817af41444ddbfa5eb9aacfa7dc58df43ce00;

    /// @dev Get cap interest harvester storage
    /// @return $ Storage pointer
    function getCapInterestHarvesterStorage()
        internal
        pure
        returns (ICapInterestHarvester.CapInterestHarvesterStorage storage $)
    {
        assembly {
            $.slot := CapInterestHarvesterStorageLocation
        }
    }
}
