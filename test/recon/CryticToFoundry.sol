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
    // NOTE: something is weird about the borrowing amount being type(uint256).max
    function test_property_debt_token_balance_gte_total_vault_debt_1() public {
        capToken_mint_clamped(10000718111);

        lender_borrow(100014444, 0x00000000000000000000000000000000DeaDBeef);

        vm.warp(block.timestamp + 6);

        vm.roll(block.number + 1);

        switchActor(1);

        // borrowing type(uint256).max here
        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        console2.log("uint256.max)", type(uint256).max);
        property_debt_token_balance_gte_total_vault_debt();
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
    // NOTE: agent health changes if the restaker rate is decreased
    // TODO: optimization test for this
    function test_lender_realizeRestakerInterest_8() public {
        switch_asset(0);

        // set initial rate to 0.5%
        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 0.05e27);

        capToken_mint_clamped(100711969);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        (,, uint256 totalDebtBefore,,, uint256 healthBefore) = _getAgentParams(_getActor());

        console2.log("rate before %e", oracle.restakerRate(_getActor()));
        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 33056249739822063734181);
        console2.log("rate after %e", oracle.restakerRate(_getActor()));

        vm.warp(block.timestamp + 56837);

        lender_realizeRestakerInterest();

        (,, uint256 totalDebtAfter,,, uint256 healthAfter) = _getAgentParams(_getActor());

        console2.log("totalDebtBefore %e", totalDebtBefore);
        console2.log("totalDebtAfter %e", totalDebtAfter);
        console2.log("healthBefore %e", healthBefore);
        console2.log("healthAfter %e", healthAfter);
        property_health_should_not_change_when_realizeRestakerInterest_is_called();
    }

    // forge test --match-test test_property_health_should_not_change_when_realizeRestakerInterest_is_called_6 -vvv
    // NOTE: same as above with the property extracted to be global
    function test_property_health_should_not_change_when_realizeRestakerInterest_is_called_6() public {
        switch_asset(0);

        capToken_mint_clamped(612047141);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 2735589900858180726609421);

        vm.warp(block.timestamp + 152);

        vm.roll(block.number + 1);

        lender_realizeRestakerInterest();

        property_health_should_not_change_when_realizeRestakerInterest_is_called();
    }

    // forge test --match-test test_lender_borrow_clamped_6 -vvv
    // NOTE: looks like truncation in LTV calculation causes the issue
    // TODO: optimization test for this
    function test_lender_borrow_clamped_6() public {
        switch_asset(0);

        delegation_modifyAgent_clamped(
            129181229575799737715131132821888667075620458965846965435092154830549421623,
            72839458564055505122023948938095823631408136626438696912038330677298861505
        );

        capToken_mint_clamped(126357672253);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        vm.warp(block.timestamp + 17866);

        vm.roll(block.number + 1);

        switchActor(1);

        vm.warp(block.timestamp + 1299632);

        vm.roll(block.number + 1);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
    }

    // forge test --match-test test_property_borrower_cannot_borrow_more_than_ltv_5 -vvv
    // NOTE: same as above with the property extracted to be global
    function test_property_borrower_cannot_borrow_more_than_ltv_5() public {
        switch_asset(0);

        capToken_mint_clamped(125007552716);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        vm.warp(block.timestamp + 1);

        vm.roll(block.number + 1);

        property_borrower_cannot_borrow_more_than_ltv();
    }

    // forge test --match-test test_capToken_burn_4 -vvv
    // NOTE: looks like a real issue, if the vault suffers a loss and reserve amount is set too high, divest call in burn reverts due to underflow
    // partial admin error, can be changed by them resetting the reserve but would require constant oversight
    function test_capToken_burn_4() public {
        capToken_mint_clamped(20000530684);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_decreaseYield(1);

        capToken_setReserve(9999523071);

        capToken_burn(10008354012, 0, 0);
    }

    // forge test --match-test test_capToken_burn_clamped_9 -vvv
    // NOTE: same as above but with the burn_clamped call instead
    function test_capToken_burn_clamped_9() public {
        capToken_mint_clamped(20002834052);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_decreaseYield(1);

        capToken_setReserve(10001776161);

        capToken_burn_clamped(10000570266);
    }

    // forge test --match-test test_doomsday_liquidate_7 -vvv
    // NOTE: fails at the call to repay
    function test_doomsday_liquidate_7() public {
        switchChainlinkOracle(2);

        capToken_mint_clamped(73605660843);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        switch_asset(0);

        mockChainlinkPriceFeed_setLatestAnswer(305875086761391717524);

        mockAaveDataProvider_setVariableBorrowRate(2);

        oracle_setBenchmarkRate(
            0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );

        doomsday_liquidate(1);
    }

    // forge test --match-test test_doomsday_repay_8 -vvv
    // NOTE: this is a subset of the above, also reverts at repay
    // TODO: optimization test that increases the amount trying to be repaid
    function test_doomsday_repay_8() public {
        capToken_mint_clamped(10000686559);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        switch_asset(0);

        oracle_setBenchmarkRate(
            0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );

        mockAaveDataProvider_setVariableBorrowRate(2);

        doomsday_repay(1);
    }

    // forge test --match-test test_doomsday_manipulate_utilization_rate_2 -vvv
    // NOTE: appears to be valid, need to discover the root cause
    function test_doomsday_manipulate_utilization_rate_2() public {
        switchActor(1);

        capToken_mint_clamped(10016233150);

        lender_borrow(100620828, 0x00000000000000000000000000000000DeaDBeef);

        doomsday_manipulate_utilization_rate(100106565);
    }

    // forge test --match-test test_doomsday_repay_all_5 -vvv
    // NOTE: looks like a real issue, realizeInterest gives an inconsistent realized interest amount compared to repay
    function test_doomsday_repay_all_5() public {
        capToken_mint_clamped(10015633476);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        // note: realizing interest explicitly errors with zero realization
        // uint256 realizedInterest = lender.realizeInterest(_getAsset());
        // console2.log("realizedInterest %e", realizedInterest);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        doomsday_repay_all();
    }

    /// === Newest Issues === ///
    // forge test --match-test test_property_no_operation_makes_user_liquidatable_2 -vvv
    // TODO: investigate further, something is wrong with setting before/after because health is actually correct but the _after call in lender_removeAsset looks like it's silently failing
    function test_property_no_operation_makes_user_liquidatable_2() public {
        capToken_mint_clamped(10002668741);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        lender_repay(10004991667);

        switch_asset(0);

        console2.log("==== REMOVE ASSET ====");
        lender_removeAsset(0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758);

        property_no_operation_makes_user_liquidatable();
    }
}
