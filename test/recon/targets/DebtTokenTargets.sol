// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/lendingPool/tokens/DebtToken.sol";

abstract contract DebtTokenTargets is BaseTargetFunctions, Properties {
/// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

/// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

// @audit info: This function can only be called by the Lender contract to burn debt tokens.
// function debtToken_burn(address from, uint256 amount) public asActor {
//     debtToken.burn(from, amount);
// }

// @audit info: This function can only be called by the Lender contract to mint debt tokens.
// function debtToken_mint(address to, uint256 amount) public asActor {
//     debtToken.mint(to, amount);
// }
}
