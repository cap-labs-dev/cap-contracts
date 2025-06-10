// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "test/mocks/MockAaveDataProvider.sol";

abstract contract MockAaveDataProviderTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function mockAaveDataProvider_setVariableBorrowRate(uint256 _variableBorrowRate) public asActor {
        // @audit-info clamped to avoid overflow in https://github.com/Recon-Fuzz/cap-contracts/blob/6c3c83daa7eec32c0394663edbea929e503d3ca4/contracts/lendingPool/tokens/DebtToken.sol#L120
        _variableBorrowRate = between(_variableBorrowRate, 0, type(uint88).max);
        mockAaveDataProvider.setVariableBorrowRate(_variableBorrowRate);
    }
}
