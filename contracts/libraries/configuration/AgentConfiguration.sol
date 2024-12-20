// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Errors } from '../helpers/Errors.sol';
import { DataTypes } from '../types/DataTypes.sol';

/**
 * @title AgentConfiguration library
 * @author kexley
 * @notice Implements the bitmap logic to handle the agent configuration
 */
library AgentConfiguration {

    uint256 internal constant BORROWING_MASK =
        0x5555555555555555555555555555555555555555555555555555555555555555;

    /**
    * @notice Sets if the user is borrowing the reserve identified by reserveIndex
    * @param self The configuration object
    * @param reserveIndex The index of the reserve in the bitmap
    * @param borrowing True if the user is borrowing the reserve, false otherwise
    */
    function setBorrowing(
        DataTypes.AgentConfigurationMap storage self,
        uint256 reserveIndex,
        bool borrowing
    ) internal {
        unchecked {
            require(reserveIndex < 256, Errors.INVALID_RESERVE_INDEX);
            uint256 bit = 1 << (reserveIndex << 1);
            if (borrowing) {
                self.data |= bit;
            } else {
                self.data &= ~bit;
            }
        }
    }

    /**
    * @notice Validate a user has been using the reserve for borrowing
    * @param self The configuration object
    * @param reserveIndex The index of the reserve in the bitmap
    * @return True if the user has been using a reserve for borrowing, false otherwise
    */
    function isBorrowing(
        DataTypes.AgentConfigurationMap memory self,
        uint256 reserveIndex
    ) internal pure returns (bool) {
        unchecked {
            require(reserveIndex < 256, Errors.INVALID_RESERVE_INDEX);
            return (self.data >> (reserveIndex << 1)) & 1 != 0;
        }
    }
}
