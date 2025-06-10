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
    // NOTE: come back to this, something is up with before/after updates
    function test_property_debt_increase_after_realizing_interest_8() public {
        capToken_mint_clamped(10000886199);

        lender_borrow_clamped(105137047);

        // console2.log(
        //     "before lender_realizeInterest _before.debtTokenBalance[_getAsset()][_getActor()]",
        //     _before.debtTokenBalance[_getAsset()][_getActor()]
        // );
        // console2.log(
        //     "before lender_realizeInterest _after.debtTokenBalance[_getAsset()][_getActor()]",
        //     _after.debtTokenBalance[_getAsset()][_getActor()]
        // );

        (,, address debtToken,,,,) = ILender(address(lender)).reservesData(_getAsset());
        console2.log("debt token balance", MockERC20(debtToken).balanceOf(_getActor()));
        console2.log("debt token total supply", MockERC20(debtToken).totalSupply());
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        lender_realizeInterest(0xD16d567549A2a2a2005aEACf7fB193851603dd70);
        console2.log("debt token balance after", MockERC20(debtToken).balanceOf(_getActor()));
        console2.log("debt token total supply after", MockERC20(debtToken).totalSupply());

        // console2.log(
        //     "after lender_realizeInterest _before.debtTokenBalance[_getAsset()][_getActor()]",
        //     _before.debtTokenBalance[_getAsset()][_getActor()]
        // );
        // console2.log(
        //     "after lender_realizeInterest _after.debtTokenBalance[_getAsset()][_getActor()]",
        //     _after.debtTokenBalance[_getAsset()][_getActor()]
        // );

        property_debt_increase_after_realizing_interest();
    }

    // forge test --match-test test_capToken_burn_clamped_3 -vvv
    // NOTE: seems like a real break with a user being able to burn without fees
    function test_capToken_burn_clamped_3() public {
        capToken_mint_clamped(20000551208);

        capToken_burn_clamped(10000683817);
    }

    // forge test --match-test test_capToken_mint_14 -vvv
    // NOTE: similar to the above, but due to a change in price
    function test_capToken_mint_14() public {
        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(500256233200780722);

        capToken_mint(
            0xD16d567549A2a2a2005aEACf7fB193851603dd70, 2, 0, 0x00000000000000000000000000000000DeaDBeef, 1525295799
        );
    }

    // forge test --match-test test_lender_repay_clamped_6 -vvv
    // NOTE: repay can revert due to underflow
    // TODO: need to determine if the call sequence is realistic or needs further clamping
    function test_lender_repay_clamped_6() public {
        switchAaveOracle(2);

        mockAaveDataProvider_setVariableBorrowRate(
            57904238167892068531037184868122078708591352565700547569692866999400797589496
        );

        lender_repay_clamped(0);
    }

    // forge test --match-test test_lender_liquidate_1 -vvv
    function test_lender_liquidate_1() public {
        capToken_mint_clamped(10003039659);

        switchChainlinkOracle(2);

        lender_borrow_clamped(101505219);

        mockChainlinkPriceFeed_setLatestAnswer(172978832219520413055122);

        lender_liquidate(0x0000000000000000000000000000000000000000, 0);
    }

    // forge test --match-test test_lender_liquidate_clamped_2 -vvv
    function test_lender_liquidate_clamped_2() public {
        capToken_mint_clamped(10020274632);

        switchChainlinkOracle(2);

        lender_borrow_clamped(1570244088);

        mockChainlinkPriceFeed_setLatestAnswer(11150459009966507495810);

        lender_liquidate_clamped(0);
    }

    // forge test --match-test test_lender_borrow_clamped_5 -vvv
    function test_lender_borrow_clamped_5() public {
        capToken_mint_clamped(10001602506);

        lender_borrow_clamped(100171022);

        vm.warp(block.timestamp + 1);

        vm.roll(block.number + 1);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
    }

    // forge test --match-test test_lender_repay_6 -vvv
    // TODO: define some realistic bounds for the borrow rate so this doesn't trivially break
    function test_lender_repay_6() public {
        mockAaveDataProvider_setVariableBorrowRate(
            57899629142092681212539648668816850347303020206421162146955475922475103470875
        );

        lender_repay(0x2a07706473244BC757E10F2a9E86fB532828afe3, 0);
    }

    // forge test --match-test test_capToken_mint_7 -vvv
    // TODO: fix to use the currently set min fee instead of 0 by default
    function test_capToken_mint_7() public {
        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(500014818870012950);
        console2.log("latest answer: %e", uint256(500014818870012950)); // 5.0001481887001295e17

        capToken_mint(
            0xD16d567549A2a2a2005aEACf7fB193851603dd70, 2, 0, 0x00000000000000000000000000000000DeaDBeef, 1525295799
        );
    }

    // forge test --match-test test_capToken_mint_clamped_11 -vvv
    // NOTE: mint just underflows for insufficient approvals
    // should it throw a custom error instead?
    function test_capToken_mint_clamped_11() public {
        asset_approve(0x796f2974e3C1af763252512dd6d521E9E984726C, 0);

        capToken_mint_clamped(10000304985);
    }

    // forge test --match-test test_capToken_mint_7 -vvv
    // NOTE: Liquidation did not improve health factor, try to invest
    function test_lender_liquidate_2() public {
        capToken_mint_clamped(6505424303794);
        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        switchChainlinkOracle(14211097524167602802493863989865037497162472790322337168572978);
        mockChainlinkPriceFeed_setLatestAnswer(2713282178368992834);
        lender_liquidate_clamped(1);
    }
}
