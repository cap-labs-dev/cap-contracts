// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { FoundryAsserts } from "@chimera/FoundryAsserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";

import { TargetFunctions } from "./TargetFunctions.sol";

import { ILender } from "contracts/interfaces/ILender.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import "forge-std/console2.sol";

import { MockERC4626Tester } from "./targets/MockERC4626TesterTargets.sol";
import { Test } from "forge-std/Test.sol";

// forge test --match-contract CryticToFoundry test/recon/CryticToFoundry.sol -vv
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

        // 6. Set the reserve to 0
        // capToken_setReserve(_getAsset(), 1e18);

        // capToken_setReserve(_getAsset(), mintAmount / 2);
        // 6. Try to withdraw a small amount that should trigger the loss condition
        // uint256 withdrawAmount = MockERC4626Tester(_getVault()).maxWithdraw(address(capToken));
        uint256 withdrawAmount = 9.9e18;
        // vault will revert if trying to withdraw more than the max withdraw amount
        // so when we divest the maxWithdraw amount, it will always succeed
        // what we really need is for currentBalance < divestAmount + assetBalance
        // in other words: currentBalance < _withdrawAmount + $.reserve[_asset] - assetBalance + assetBalance
        // which is equivalent to: currentBalance < _withdrawAmount + $.reserve[_asset]
        // we know _withdrawAmount <= maxWithdraw amount, so we need to make $.reserve[_asset] increase
        // doesn't seem like the LossFromFractionalReserve line is reachable because it would require withdrawing an amount that's less than what was deposited
        capToken_burn_clamped(withdrawAmount);
    }

    // forge test --match-test test_property_vault_solvency_assets_3 -vvv
    // NOTE: an unrealized loss causes the totalSupplied to be greater than the vault balance + totalBorrows + fractionalReserveBalance
    // TODO: confirm what the impact of this is on the rest of the system
    function test_property_vault_solvency_assets_3() public {
        switch_asset(1);

        add_new_vault();

        capToken_setFractionalReserveVault_clamped();

        capToken_mint_clamped(1);

        capToken_investAll(0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7);

        mockERC4626Tester_simulateLoss(1);

        property_vault_solvency_assets();
    }

    // forge test --match-test test_property_borrowed_asset_value_7 -vvv
    // NOTE: broken before, fixed with new mockNetworkMiddleware
    function test_property_borrowed_asset_value_7() public {
        mockNetworkMiddleware_setMockCollateralByVault(0x0000000000000000000000000000000000000000, 1);

        property_borrowed_asset_value();
    }

    // forge test --match-test test_property_debt_increase_after_realizing_interest_8 -vvv
    // NOTE: this requires fixing the use of the agent and replacing with just actor in the handlers
    function test_property_debt_increase_after_realizing_interest_8() public {
        capToken_mint_clamped(10000886199);

        lender_borrow_clamped(105137047);
        (,, address debtToken,,,,) = ILender(address(lender)).reservesData(_getAsset());
        console2.log("debt token balance", MockERC20(debtToken).balanceOf(_getActor()));
        console2.log("debt token total supply", MockERC20(debtToken).totalSupply());
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        lender_realizeInterest(0xD16d567549A2a2a2005aEACf7fB193851603dd70);
        console2.log("debt token balance after", MockERC20(debtToken).balanceOf(_getActor()));
        console2.log("debt token total supply after", MockERC20(debtToken).totalSupply());

        uint256 debtIncrease =
            _after.debtTokenBalance[_getAsset()][_getActor()] - _before.debtTokenBalance[_getAsset()][_getActor()];
        uint256 borrowsIncrease = _after.totalBorrows[_getAsset()] - _before.totalBorrows[_getAsset()];
        console2.log(
            "_after.debtTokenBalance[_getAsset()][_getActor()]", _after.debtTokenBalance[_getAsset()][_getActor()]
        );
        console2.log(
            "_before.debtTokenBalance[_getAsset()][_getActor()]", _before.debtTokenBalance[_getAsset()][_getActor()]
        );
        console2.log("_after.totalBorrows[_getAsset()]", _after.totalBorrows[_getAsset()]);
        console2.log("_before.totalBorrows[_getAsset()]", _before.totalBorrows[_getAsset()]);

        property_debt_increase_after_realizing_interest();
    }

    // forge test --match-test test_property_utilization_ratio_9 -vvv
    function test_property_utilization_ratio_9() public {
        capToken_mint_clamped(10002632831);

        lender_borrow_clamped(100014152);

        property_utilization_ratio();
    }
}
