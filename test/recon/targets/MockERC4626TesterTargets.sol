// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import { Properties } from "../Properties.sol";
import { MockERC4626Tester } from "../mocks/MockERC4626Tester.sol";

abstract contract MockERC4626TesterTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function mockERC4626Tester_approve(address spender, uint256 value) public asActor {
        MockERC4626Tester(_getVault()).approve(spender, value);
    }

    function mockERC4626Tester_decreaseYield(uint256 decreasePercentageFP4) public asActor {
        MockERC4626Tester(_getVault()).decreaseYield(decreasePercentageFP4);
    }

    function mockERC4626Tester_increaseYield(uint256 increasePercentageFP4) public asActor {
        MockERC4626Tester(_getVault()).increaseYield(increasePercentageFP4);
    }

    function mockERC4626Tester_setDecimalsOffset(uint8 targetDecimalsOffset) public asActor {
        MockERC4626Tester(_getVault()).setDecimalsOffset(targetDecimalsOffset);
    }

    function mockERC4626Tester_transfer(address to, uint256 value) public asActor {
        MockERC4626Tester(_getVault()).transfer(to, value);
    }

    function mockERC4626Tester_transferFrom(address from, address to, uint256 value) public asActor {
        MockERC4626Tester(_getVault()).transferFrom(from, to, value);
    }

    // NOTE: ERC4626 vaults being used as fractional reserves will not take losses on withdraw
    // function mockERC4626Tester_setLossOnWithdraw(uint256 lossOnWithdraw) public asActor {
    //     MockERC4626Tester(_getVault()).setLossOnWithdraw(lossOnWithdraw);
    // }
}
