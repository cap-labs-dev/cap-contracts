// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";

/// @title InterestRateModel Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for InterestRateModel
abstract contract InterestRateModelStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.InterestRateModel")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INTEREST_RATE_MODEL_STORAGE_LOCATION =
        0xd89b2c6380858838b49012bca597e269bf6ad7de24b14afcc69ceb25d5be0000;

    /// @dev Get InterestRateModel storage
    /// @return $ Storage pointer
    function getInterestRateModelStorage() internal pure returns (IInterestRateModel.Storage storage $) {
        assembly {
            $.slot := INTEREST_RATE_MODEL_STORAGE_LOCATION
        }
    }
}
