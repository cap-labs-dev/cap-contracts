// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IRewarder } from "../interfaces/IRewarder.sol";

/// @title Rewarder Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for Rewarder
abstract contract RewarderStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Rewarder")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REWARDER_STORAGE_LOCATION =
        0xfb03a101921641f3594e902606cf14ab0aec0edfa2ce04d2d523e35c408ae700;

    /// @dev Get Rewarder storage
    /// @return $ Storage pointer
    function getRewarderStorage() internal pure returns (IRewarder.Storage storage $) {
        assembly {
            $.slot := REWARDER_STORAGE_LOCATION
        }
    }
}
