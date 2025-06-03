// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { FoundryAsserts } from "@chimera/FoundryAsserts.sol";

import "forge-std/console2.sol";

import { TargetFunctions } from "./TargetFunctions.sol";

import { MockERC4626Tester } from "./targets/MockERC4626TesterTargets.sol";
import { Test } from "forge-std/Test.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {
        // TODO: add failing property tests here for debugging
    }

    function test_fractional_reserve_loss() public {
        // 1. Create a new vault
        add_new_vault();

        // 2. Set up the fractional reserve vault
        capToken_setFractionalReserveVault_clamped();

        // 3. Mint CapToken with the asset
        uint256 mintAmount = 1e18; // 1 token with 18 decimals
        capToken_mint(_getAsset(), mintAmount, 0, _getActor(), block.timestamp + 1 days);

        // 4. Invest all assets in the CapToken
        capToken_investAll(_getAsset());

        // 5. Decrease the yield of the vault to simulate a loss
        mockERC4626Tester_simulateLoss(1e17); // 10% loss

        // capToken_setReserve(_getAsset(), mintAmount / 2);
        // 6. Try to withdraw a small amount that should trigger the loss condition
        // uint256 withdrawAmount = MockERC4626Tester(_getVault()).maxWithdraw(address(capToken));
        uint256 withdrawAmount = 1e18;
        console2.log("withdrawAmount: %e", withdrawAmount);
        // vault will revert if trying to withdraw more than the max withdraw amount
        // so when we divest the maxWithdraw amount, it will always succeed
        // what we really need is for currentBalance < divestAmount + assetBalance
        // in other words: currentBalance < _withdrawAmount + $.reserve[_asset] - assetBalance + assetBalance
        // which is equivalent to: currentBalance < _withdrawAmount + $.reserve[_asset]
        // we know _withdrawAmount <= maxWithdraw amount, so we need to make $.reserve[_asset] increase
        // doesn't seem like the LossFromFractionalReserve line is reachable because it would require withdrawing an amount that's less than what was deposited
        capToken_burn_clamped(withdrawAmount);
    }
}
