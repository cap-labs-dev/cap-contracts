// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { FoundryAsserts } from "@chimera/FoundryAsserts.sol";

import "forge-std/console2.sol";

import { TargetFunctions } from "./TargetFunctions.sol";
import { Test } from "forge-std/Test.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {
        // TODO: add failing property tests here for debugging
        capToken_mint_clamped(100e18);
        lender_borrow_clamped(1e18);
        mockNetworkMiddleware_setMockSlashableCollateral_clamped(true);
        lender_initiateLiquidation_clamped();
        mockNetworkMiddleware_setMockSlashableCollateral_clamped(false);
        // vm.warp(block.timestamp + 1 days);
        // lender_repay_clamped(1e18);
        // lender_liquidate(_getActor(), address(capToken), 1e18);
    }
}
