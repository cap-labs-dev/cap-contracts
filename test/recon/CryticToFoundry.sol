// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { FoundryAsserts } from "@chimera/FoundryAsserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

import { ILender } from "contracts/interfaces/ILender.sol";
import { IOracle } from "contracts/interfaces/IOracle.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

import { TargetFunctions } from "./TargetFunctions.sol";
import { MockERC4626Tester } from "./targets/MockERC4626TesterTargets.sol";

// forge test --match-contract CryticToFoundry test/recon/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {
        // TODO: add failing property tests here for debugging
    }

    // forge test --match-test test_capToken_redeem_clamped_6 -vvv
    // NOTE: issue is because of implementation of ERC4626Tester, need to determine best way to fix behavior
    // TODO: determine best way to fix ERC4626Tester behavior
    // NOTE: this no longer fails with the check for user allowance included because it was reverting before the cUSD was burned for the user
    function test_capToken_redeem_clamped_6() public {
        capToken_mint_clamped(10000037441);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        // issue is because shares in withdraw calculated by previewWithdraw now get increased but user balance doesn't
        // most likely fix would be to rebase shares for all users when unbacked shares are minted
        // or just make it so that users can only withdraw up to the maxWithdraw amount
        // mockERC4626Tester_mintUnbackedShares(100003377823040994724, 0x0000000000000000000000000000000000000000);
        // mockERC4626Tester_simulateLoss(200);

        capToken_redeem_clamped(1);
    }

    /// === Newest Issues === ///

    // forge test --match-test test_lender_liquidate_0 -vvv
    // NOTE: Liquidation did not improve health factor, related to oracle price, looks Low
    function test_lender_liquidate_0() public {
        switchActor(1);

        capToken_mint_clamped(10005653326);

        lender_borrow(501317817, 0x00000000000000000000000000000000DeaDBeef);

        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(49869528211447337507581);

        lender_liquidate(1);
    }

    // forge test --match-test test_property_debt_token_balance_gte_total_vault_debt_1 -vvv
    // NOTE: DebtToken balance < total vault debt, this looks valid
    function test_property_debt_token_balance_gte_total_vault_debt_1() public {
        capToken_mint_clamped(10000718111);

        lender_borrow(100014444, 0x00000000000000000000000000000000DeaDBeef);

        vm.warp(block.timestamp + 6);

        vm.roll(block.number + 1);

        switchActor(1);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        property_debt_token_balance_gte_total_vault_debt();
    }

    // forge test --match-test test_capToken_burn_clamped_4 -vvv
    // NOTE: user received more than expected amount out, this looks valid
    function test_capToken_burn_clamped_4() public {
        capToken_mint_clamped(10000718111);

        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(56196342554784885);

        capToken_burn_clamped(14217);
    }

    // forge test --match-test test_capToken_mint_clamped_6 -vvv
    // NOTE: minted cUSD is less than the asset value received, this looks valid and related to
    // cUSD price increases unexpectedly (oracle price of cUSD 100000000 -> 104000000)
    // We should determine if the math in property is correct
    function test_capToken_mint_clamped_6() public {
        capToken_mint_clamped(249999999999);

        capToken_mint_clamped(10000107608);
    }

    // forge test --match-test test_lender_realizeRestakerInterest_8 -vvv
    // NOTE: Make sure this property should hold: agent total debt should not change after realizeRestakerInterest
    function test_lender_realizeRestakerInterest_8() public {
        switch_asset(0);

        capToken_mint_clamped(100711969);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 33056249739822063734181);

        vm.warp(block.timestamp + 56837);

        lender_realizeRestakerInterest();
    }
}
