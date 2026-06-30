// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IInverseInterestRateModel } from "../interfaces/IInverseInterestRateModel.sol";

/// @title InverseInterestRateModel Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for InverseInterestRateModel
abstract contract InverseInterestRateModelStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.InverseInterestRateModel")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INVERSE_INTEREST_RATE_MODEL_STORAGE_LOCATION =
        0xe316163b9971e241005d6cd4e4876cbcbe6fe9b671331f132138db42c6e4ec00;

    /// @dev Get InverseInterestRateModel storage
    /// @return $ Storage pointer
    function getInverseInterestRateModelStorage()
        internal
        pure
        returns (IInverseInterestRateModel.InverseInterestRateModelStorage storage $)
    {
        assembly {
            $.slot := INVERSE_INTEREST_RATE_MODEL_STORAGE_LOCATION
        }
    }
}
