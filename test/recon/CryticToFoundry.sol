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

        lender_borrow(501317817);

        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(49869528211447337507581);

        lender_liquidate(1);
    }

    // forge test --match-test test_property_debt_token_balance_gte_total_vault_debt_1 -vvv
    // NOTE: DebtToken balance < total vault debt, this looks valid
    // NOTE: something is weird about the borrowing amount being type(uint256).max
    function test_property_debt_token_balance_gte_total_vault_debt_1() public {
        capToken_mint_clamped(10000718111);

        lender_borrow(100014444);

        vm.warp(block.timestamp + 6);

        vm.roll(block.number + 1);

        switchActor(1);

        // borrowing type(uint256).max here
        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        doomsday_debt_token_solvency();
    }

    // forge test --match-test test_capToken_mint_clamped_6 -vvv
    // NOTE: minted cUSD is less than the asset value received, this looks valid and related to
    // cUSD price increases unexpectedly (oracle price of cUSD 100000000 -> 104000000)
    // We should determine if the math in property is correct
    function test_capToken_mint_clamped_6() public {
        capToken_mint_clamped(249999999999);

        capToken_mint_clamped(10000107608);
    }

    // forge test --match-test test_property_health_should_not_change_when_realizeRestakerInterest_is_called_6 -vvv
    // NOTE: agent health changes if the restaker rate is decreased
    // TODO: optimization test for this
    function test_property_health_should_not_change_when_realizeRestakerInterest_is_called_6() public {
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
        console2.log("maxDecreaseHealthDelta %e", maxDecreaseHealthDelta);
        console2.log("optimize_max_health_decrease %e", optimize_max_health_decrease());

        property_health_should_not_change_when_realizeRestakerInterest_is_called();
    }

    // forge test --match-test test_doomsday_manipulate_utilization_rate_2 -vvv
    // NOTE: appears to be valid, need to discover the root cause
    function test_doomsday_manipulate_utilization_rate_2() public {
        switchActor(1);

        capToken_mint_clamped(10016233150);

        lender_borrow(100620828);

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

    // forge test --match-test test_property_zero_debt_is_borrowing_0 -vvv
    // NOTE: looks like a real issue, user can have 0 debt but still be borrowing
    function test_property_zero_debt_is_borrowing_0() public {
        capToken_mint_clamped(1210366228196525416932125);

        lender_borrow_clamped(381970873);

        lender_repay(381970873);

        property_zero_debt_is_borrowing();
    }

    /// === Newest Issues === ///
    // forge test --match-test test_lender_borrow_clamped_13 -vvv
    function test_lender_borrow_clamped_13() public {
        switch_asset(0);

        capToken_mint_clamped(114947380);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 292733041588401904719173);

        capToken_mint_clamped(124892572629);

        vm.warp(block.timestamp + 6620);

        vm.roll(block.number + 1);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
    }

    // forge test --match-test test_property_cap_token_backed_1_to_1_12 -vvv
    function test_property_cap_token_backed_1_to_1_12() public {
        capToken_mint_clamped(20000530684);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        capToken_setReserve(101037885);

        capToken_burn_clamped(10006208396);

        capToken_setFractionalReserveVault();

        property_cap_token_backed_1_to_1();
    }

    // forge test --match-test test_property_health_should_not_change_when_realizeRestakerInterest_is_called_otwb -vvv
    //     function test_property_health_should_not_change_when_realizeRestakerInterest_is_called_otwb() public {

    //         switch_asset(0);

    //         capToken_mint_clamped(612047141);

    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,2735589900858180726609421);

    //         vm.warp(block.timestamp + 152);

    //         vm.roll(block.number + 1);

    //         lender_realizeRestakerInterest();

    //         property_health_should_not_change_when_realizeRestakerInterest_is_called();

    //     }

    // // forge test --match-test test_property_borrower_cannot_borrow_more_than_ltv_munu -vvv
    //     function test_property_borrower_cannot_borrow_more_than_ltv_munu() public {

    //         switch_asset(0);

    //         capToken_mint_clamped(125007552716);

    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.warp(block.timestamp + 1);

    //         vm.roll(block.number + 1);

    //         property_borrower_cannot_borrow_more_than_ltv();

    //     }

    // // forge test --match-test test_doomsday_liquidate_udr8 -vvv
    //     function test_doomsday_liquidate_udr8() public {

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 52772);
    //         vm.warp(block.timestamp + 305996);
    //         stakedCap_deposit(51895644719467792066571894091710869393543355905728171984000194425741445815407,0x0000000000000000000000000000000000000f02);

    //         vm.roll(block.number + 32651);
    //         vm.warp(block.timestamp + 150273);
    //         lender_realizeRestakerInterest();

    //         vm.roll(block.number + 38369);
    //         vm.warp(block.timestamp + 387502);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 17085);
    //         vm.warp(block.timestamp + 283490);
    //         oracle_setPriceOracleData(0x00000000000000000000000000000001fffffffE,(0x00000000000000000000000000000000FFFFfFFF, hex"a3edc7b1");

    //         vm.roll(block.number + 33175);
    //         vm.warp(block.timestamp + 114565);
    //         accessControl_grantRole(hex"8fa0e6d4e940ab4d8ed5aa3d1799d92ae4580c499a566cf326359d2f8c2639190c63",0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 153418);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 51642);
    //         vm.warp(block.timestamp + 455740);
    //         capToken_investAll();

    //         vm.roll(block.number + 45626);
    //         vm.warp(block.timestamp + 275394);
    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 9);
    //         vm.warp(block.timestamp + 322310);
    //         accessControl_grantRole(hex"94193014c9b6b1d8263037776f0dd1affe687a4510259762f85409a0f681263792",0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    //         vm.roll(block.number + 32652);
    //         vm.warp(block.timestamp + 3866);
    //         mockERC4626Tester_decreaseYield(1889567281);

    //         vm.roll(block.number + 23640);
    //         vm.warp(block.timestamp + 105767);
    //         stakedCap_permit(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000001fffffffE,115792089237316195423570985008687907853269984665640564039457584007910970861364,39999,71,hex"436861696e6c696e6b416461707465724e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",hex"ecf4b64e554c275b8ce78f01677dfb40b0f3e8e568c883790c6479dda0d4cf2630b989");

    //         vm.roll(block.number + 30076);
    //         vm.warp(block.timestamp + 114028);
    //         add_new_vault();

    //         vm.roll(block.number + 50591);
    //         vm.warp(block.timestamp + 360624);
    //         delegation_modifyAgent(0x00000000000000000000000000000002fFffFffD,97437886507539518163380950116378087205531315758316206396361808311906109294232,55009056653247864666333227221290549104086798899090742194442548208928341184104);

    //         vm.roll(block.number + 17402);
    //         vm.warp(block.timestamp + 415353);
    //         property_no_operation_makes_user_liquidatable();

    //         vm.roll(block.number + 4992);
    //         vm.warp(block.timestamp + 248143);
    //         capToken_mint_clamped(115792089237316195423570985008687907853269984665640564039457584007912725541410);

    //         vm.roll(block.number + 4988);
    //         vm.warp(block.timestamp + 566039);
    //         feeReceiver_setProtocolFeePercentage(21177001980913072561819178958892421069922519463453665913879856898691208300997);

    //         vm.roll(block.number + 64);
    //         vm.warp(block.timestamp + 322310);
    //         switch_asset(41741672455936636067528016515028481856449239464882683431390667937752762994943);

    //         vm.roll(block.number + 15978);
    //         vm.warp(block.timestamp + 511822);
    //         capToken_divestAll();

    //         vm.roll(block.number + 60267);
    //         vm.warp(block.timestamp + 94247);
    //         property_sum_of_unrealized_interest();

    //         vm.roll(block.number + 42691);
    //         vm.warp(block.timestamp + 520294);
    //         stakedCap_approve(0x89CA9F4f77B267778EB2eA0Ba1bEAdEe8523af36,79263329071277027581233815940519289961848523410226965916996223147216987245638);

    //         vm.roll(block.number + 15977);
    //         vm.warp(block.timestamp + 37);
    //         capToken_mint_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 3599);
    //         vm.warp(block.timestamp + 279910);
    //         feeAuction_setDuration(4556814846701759218819019656812368086479265741890454661892085911045191203525);

    //         vm.roll(block.number + 37011);
    //         vm.warp(block.timestamp + 51723);
    //         mockERC4626Tester_decreaseYield(31536000);

    //         vm.roll(block.number + 33);
    //         vm.warp(block.timestamp + 322276);
    //         mockChainlinkPriceFeed_setLatestAnswer(1000000000000000000000000000);

    //         vm.roll(block.number + 12231);
    //         vm.warp(block.timestamp + 207808);
    //         lender_repay(115792089237316195423570985008687907853269984665639564039457584007913129639938);

    //         vm.roll(block.number + 39351);
    //         vm.warp(block.timestamp + 333577);
    //         stakedCap_withdraw(115792089237316195423570985008687907853269984665640564039457584007913129639931,0x00000000000000000000000000000001fffffffE,0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758);

    //         vm.roll(block.number + 4768);
    //         vm.warp(block.timestamp + 358061);
    //         property_total_system_collateralization();

    //         vm.roll(block.number + 4943);
    //         vm.warp(block.timestamp + 276463);
    //         capToken_rescueERC20(0x0000000000000000000000000000000000000F08,0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28699);
    //         vm.warp(block.timestamp + 459450);
    //         oracle_setStaleness(0x0000000000000000000000000000000000030000,115792089237316195423570985008687907853269984665639864039457584007913129639935);

    //         vm.roll(block.number + 31650);
    //         vm.warp(block.timestamp + 126794);
    //         switch_asset(66279628312454238309986809072845170538214706825554513756466068105325613135788);

    //         vm.roll(block.number + 14276);
    //         vm.warp(block.timestamp + 243804);
    //         property_cap_token_backed_1_to_1();

    //         vm.roll(block.number + 13865);
    //         vm.warp(block.timestamp + 258936);
    //         switchAaveOracle(559);

    //         vm.roll(block.number + 15005);
    //         vm.warp(block.timestamp + 410161);
    //         oracle_setStaleness(0x0000000000000000000000000000000000000f04,4861044271986029130504069374348869141115784292321862497109123663516286428081);

    //         vm.roll(block.number + 1);
    //         vm.warp(block.timestamp + 410160);
    //         accessControl_grantAccess(hex"dcdb535458"",0x0000000000000000000000000000000000000F03,0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 27136);
    //         vm.warp(block.timestamp + 321220);
    //         mockChainlinkPriceFeed_setLatestAnswer_clamped(29932957227046301050576069155259531341489774140015701959429479400917695412244);

    //         vm.roll(block.number + 40540);
    //         vm.warp(block.timestamp + 521319);
    //         capToken_divestAll();

    //         vm.roll(block.number + 30633);
    //         vm.warp(block.timestamp + 187011);
    //         stakedCap_notify();

    //         vm.roll(block.number + 35200);
    //         vm.warp(block.timestamp + 322119);
    //         mockChainlinkPriceFeed_setMockPriceStaleness(112421130013290556312037275319089405478444714642186566594712735527215343907329);

    //         vm.roll(block.number + 8782);
    //         vm.warp(block.timestamp + 136777);
    //         mockERC4626Tester_transferFrom(0x00000000000000000000000000000001fffffffE,0x13aa49bAc059d709dd0a18D6bb63290076a702D7,41741672455936636067528016515028481856449239464882683431390667937752762994943);

    //         vm.roll(block.number + 4958);
    //         vm.warp(block.timestamp + 7);
    //         capToken_setReserve(76865952042974368188585309973152465185800955404544546579710425162064945182809);

    //         vm.roll(block.number + 41309);
    //         vm.warp(block.timestamp + 410162);
    //         capToken_transferFrom(0x94771550282853f6E0124c302F7dE1Cf50aa45CA,0x0000000000000000000000000000000000000f05,80253695358142051332775487714461999806836698418093370999575083011949937285554);

    //         vm.roll(block.number + 4994);
    //         vm.warp(block.timestamp + 34091);
    //         capToken_addAsset();

    //         vm.roll(block.number + 20236);
    //         vm.warp(block.timestamp + 471436);
    //         asset_mint(0x0000000000000000000000000000000000000F06,91317798539624585967577475848930478770);

    //     }

    // // forge test --match-test test_property_cap_token_backed_1_to_1_37ux -vvv
    //     function test_property_cap_token_backed_1_to_1_37ux() public {

    //         vm.roll(block.number + 41859);
    //         vm.warp(block.timestamp + 347393);
    //         capToken_divestAll(0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 16254);
    //         vm.warp(block.timestamp + 4573);
    //         capToken_addAsset(0x0000000000000000000000000000000000000f05);

    //         vm.roll(block.number + 26048);
    //         vm.warp(block.timestamp + 322360);
    //         mockNetworkMiddleware_slash(0x00000000000000000000000000000002fFffFffD,115792089237316195423570985008687907853269984665640564039457584007913129639933,281474976710652);

    //         vm.roll(block.number + 28698);
    //         vm.warp(block.timestamp + 311574);
    //         delegation_addAgent(0x0000000000000000000000000000000000000f04,0x00000000000000000000000000000002fFffFffD,58,801);

    //         vm.roll(block.number + 26802);
    //         vm.warp(block.timestamp + 210610);
    //         lender_borrow(0x13aa49bAc059d709dd0a18D6bb63290076a702D7,115792089237316195423570985008687907853269984665640559039457584007913129639936,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 28782);
    //         vm.warp(block.timestamp + 287316);
    //         switchChainlinkOracle(76217427352328356627645118163324938956159920411375779826128414209374083059917);

    //         vm.roll(block.number + 29826);
    //         vm.warp(block.timestamp + 322310);
    //         oracle_setPriceOracleData(0xD16d567549A2a2a2005aEACf7fB193851603dd70,(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, hex"a49d293b1e05db814c9ad4103f89105727652de843");

    //         vm.roll(block.number + 15582);
    //         vm.warp(block.timestamp + 39824);
    //         capToken_setFractionalReserveVault(0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240,0x3Cff5E7eBecb676c3Cb602D0ef2d46710b88854E);

    //         vm.roll(block.number + 25398);
    //         vm.warp(block.timestamp + 529825);
    //         oracle_setBenchmarkRate(0x00000000000000000000000000000001fffffffE,39469312234599493371890412776746681613834548022832625613442263949097069373003);

    //         vm.roll(block.number + 39519);
    //         vm.warp(block.timestamp + 282374);
    //         stakedCap_transferFrom(0x00000000000000000000000000000001fffffffE,0x00000000000000000000000000000000FFFFfFFF,190);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 321220);
    //         capToken_rescueERC20(0xF62849F9A0B5Bf2913b396098F7c7019b51A820a,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 54809);
    //         vm.warp(block.timestamp + 166861);
    //         property_vault_solvency_assets();

    //     }

    // // forge test --match-test test_capToken_divestAll_q1q7 -vvv
    //     function test_capToken_divestAll_q1q7() public {

    //         vm.roll(block.number + 45852);
    //         vm.warp(block.timestamp + 520294);
    //         oracle_setPriceOracleData(0xD16d567549A2a2a2005aEACf7fB193851603dd70,(0x0000000000000000000000000000000000000F0c, hex"7bdb4ccff76cd8192a419f9e");

    //         vm.roll(block.number + 7322);
    //         vm.warp(block.timestamp + 419861);
    //         lender_initiateLiquidation();

    //     }

    // // forge test --match-test test_doomsday_repay_all_yu9o -vvv
    //     function test_doomsday_repay_all_yu9o() public {

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 52772);
    //         vm.warp(block.timestamp + 305996);
    //         stakedCap_deposit(51895644719467792066571894091710869393543355905728171984000194425741445815407,0x0000000000000000000000000000000000000f02);

    //         vm.roll(block.number + 32651);
    //         vm.warp(block.timestamp + 150273);
    //         lender_realizeRestakerInterest();

    //         vm.roll(block.number + 38369);
    //         vm.warp(block.timestamp + 387502);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 17085);
    //         vm.warp(block.timestamp + 283490);
    //         oracle_setPriceOracleData(0x00000000000000000000000000000001fffffffE,(0x00000000000000000000000000000000FFFFfFFF, hex"a3edc7b1");

    //         vm.roll(block.number + 33175);
    //         vm.warp(block.timestamp + 114565);
    //         accessControl_grantRole(hex"8fa0e6d4e940ab4d8ed5aa3d1799d92ae4580c499a566cf326359d2f8c2639190c63",0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 153418);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 51642);
    //         vm.warp(block.timestamp + 455740);
    //         capToken_investAll();

    //         vm.roll(block.number + 45626);
    //         vm.warp(block.timestamp + 275394);
    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 9);
    //         vm.warp(block.timestamp + 322310);
    //         accessControl_grantRole(hex"94193014c9b6b1d8263037776f0dd1affe687a4510259762f85409a0f681263792",0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    //         vm.roll(block.number + 32652);
    //         vm.warp(block.timestamp + 3866);
    //         mockERC4626Tester_decreaseYield(1889567281);

    //         vm.roll(block.number + 23640);
    //         vm.warp(block.timestamp + 105767);
    //         stakedCap_permit(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000001fffffffE,115792089237316195423570985008687907853269984665640564039457584007910970861364,39999,71,hex"436861696e6c696e6b416461707465724e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",hex"ecf4b64e554c275b8ce78f01677dfb40b0f3e8e568c883790c6479dda0d4cf2630b989");

    //         vm.roll(block.number + 59502);
    //         vm.warp(block.timestamp + 322347);
    //         property_ltv();

    //         vm.roll(block.number + 5053);
    //         vm.warp(block.timestamp + 390587);
    //         stakedCap_withdraw(115792089237316195423570985008687907853269984665640564039457584007913029639935,0x886D6d1eB8D415b00052828CD6d5B321f072073d,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 16063);
    //         vm.warp(block.timestamp + 38885);
    //         property_repaid_debt_equals_zero_debt();

    //         vm.roll(block.number + 101);
    //         vm.warp(block.timestamp + 23094);
    //         lender_liquidate(115792089237316195423570985008687907853269984665640564039457584007910970861362);

    //         vm.roll(block.number + 23167);
    //         vm.warp(block.timestamp + 222375);
    //         capToken_approve(0x0000000000000000000000000000000000000f02,50186849216440882834365773503793987581223009780705702046838983657059356594816);

    //         vm.roll(block.number + 81);
    //         vm.warp(block.timestamp + 361136);
    //         feeAuction_setMinStartPrice(3210730645604);

    //         vm.roll(block.number + 12232);
    //         vm.warp(block.timestamp + 208886);
    //         doomsday_liquidate(77784623682452896297276757612921833371589091981796380949434520261093249435818);

    //         vm.roll(block.number + 50312);
    //         vm.warp(block.timestamp + 270654);
    //         capToken_realizeInterest(0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 35507);
    //         vm.warp(block.timestamp + 559698);
    //         lender_realizeInterest();

    //         vm.roll(block.number + 14020);
    //         vm.warp(block.timestamp + 205328);
    //         delegation_modifyAgent(0x00000000000000000000000000000002fFffFffD,10925763039789306535304972965395409557844302766103280259662591945254263709314,82378078954299377961602844411987608210834747384499134083242187579854035784489);

    //         vm.roll(block.number + 5140);
    //         vm.warp(block.timestamp + 11);
    //         lender_liquidate(91352034832010926057001582751876410893860910903135406657784615168643518944324);

    //         vm.roll(block.number + 20937);
    //         vm.warp(block.timestamp + 384687);
    //         capToken_investAll();

    //         vm.roll(block.number + 49063);
    //         vm.warp(block.timestamp + 322339);
    //         property_ltv();

    //         vm.roll(block.number + 800);
    //         vm.warp(block.timestamp + 166862);
    //         feeReceiver_setProtocolFeeReceiver(0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 21357);
    //         vm.warp(block.timestamp + 16802);
    //         mockAaveDataProvider_setVariableBorrowRate(60177033920751208088136462691776663159377938138205104852631179029471953460793);

    //         vm.roll(block.number + 14215);
    //         vm.warp(block.timestamp + 315003);
    //         property_staked_cap_value_non_decreasing();

    //         vm.roll(block.number + 14019);
    //         vm.warp(block.timestamp + 311576);
    //         capToken_mint_clamped(56548683243710153011124555768108935019413909561775418266312903711137308197120);

    //         vm.roll(block.number + 254);
    //         vm.warp(block.timestamp + 114026);
    //         feeReceiver_distribute();

    //         vm.roll(block.number + 26049);
    //         vm.warp(block.timestamp + 455741);
    //         mockERC4626Tester_transfer(0xe54a55121A47451c5727ADBAF9b9FC1643477e25,115792089237316195423570985008687907853269984665640564039457584007913129553536);

    //         vm.roll(block.number + 57375);
    //         vm.warp(block.timestamp + 419861);
    //         doomsday_dust_on_redeem();

    //         vm.roll(block.number + 19933);
    //         vm.warp(block.timestamp + 115085);
    //         mockChainlinkPriceFeed_setLatestAnswer_clamped(-57896044618658097711785492504343953926634992332820282019728792003956564819968);

    //         vm.roll(block.number + 1984);
    //         vm.warp(block.timestamp + 82672);
    //         delegation_addAgent(0x00000000000000000000000000000002fFffFffD,0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f,32461938627532109655386966209680202686265168587148184984455650102759133506046,19135459552296935388090104790749168797757153696639071150179259876937001456826);

    //         vm.roll(block.number + 8447);
    //         vm.warp(block.timestamp + 440097);
    //         mockAaveDataProvider_setVariableBorrowRate(122);

    //         vm.roll(block.number + 27404);
    //         vm.warp(block.timestamp + 358061);
    //         feeReceiver_distribute();

    //         vm.roll(block.number + 11942);
    //         vm.warp(block.timestamp + 376096);
    //         lender_borrow(1524785992);

    //         vm.roll(block.number + 33357);
    //         vm.warp(block.timestamp + 379552);
    //         property_health_should_not_change_when_realizeRestakerInterest_is_called();

    //         vm.roll(block.number + 23722);
    //         vm.warp(block.timestamp + 436727);
    //         property_ltv();

    //         vm.roll(block.number + 5053);
    //         vm.warp(block.timestamp + 135921);
    //         oracle_setStaleness(0x0000000000000000000000000000000000000f02,113781589314039280467394802092770976895741664446497382437655313201736093250036);

    //         vm.roll(block.number + 42595);
    //         vm.warp(block.timestamp + 547623);
    //         stakedCap_transfer(0x00000000000000000000000000000000FFFFfFFF,1524785992);

    //         vm.roll(block.number + 4462);
    //         vm.warp(block.timestamp + 521319);
    //         stakedCap_transferFrom(0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000001fffffffE,0);

    //         vm.roll(block.number + 38350);
    //         vm.warp(block.timestamp + 305572);
    //         capToken_setReserve(569);

    //         vm.roll(block.number + 53166);
    //         vm.warp(block.timestamp + 289607);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 12053);
    //         vm.warp(block.timestamp + 19029);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 12053);
    //         vm.warp(block.timestamp + 400981);
    //         switchChainlinkOracle(732);

    //         vm.roll(block.number + 127);
    //         vm.warp(block.timestamp + 436727);
    //         feeAuction_setStartPrice(46013170742117740576639226900063730366259028196008622081111656849683409321696);

    //         vm.roll(block.number + 58783);
    //         vm.warp(block.timestamp + 405856);
    //         doomsday_dust_on_redeem();

    //         vm.roll(block.number + 30132);
    //         vm.warp(block.timestamp + 4177);
    //         property_sum_of_withdrawals();

    //         vm.roll(block.number + 12155);
    //         vm.warp(block.timestamp + 67960);
    //         capToken_setWhitelist(0xD16d567549A2a2a2005aEACf7fB193851603dd70,true);

    //         vm.roll(block.number + 60248);
    //         vm.warp(block.timestamp + 588255);
    //         mockERC4626Tester_setDecimalsOffset(59);

    //         vm.roll(block.number + 53349);
    //         vm.warp(block.timestamp + 115085);
    //         oracle_setBenchmarkRate(0xe54a55121A47451c5727ADBAF9b9FC1643477e25,50044649213945947451802727009396577372587911015090060243527426738178676793393);

    //         vm.roll(block.number + 53011);
    //         vm.warp(block.timestamp + 156190);
    //         lender_borrow_clamped(105401734225248569624449427156461402920370323278279799159960827907367831910641);

    //     }

    // // forge test --match-test test_doomsday_dust_on_redeem_zhsy -vvv
    //     function test_doomsday_dust_on_redeem_zhsy() public {

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 52772);
    //         vm.warp(block.timestamp + 305996);
    //         stakedCap_deposit(51895644719467792066571894091710869393543355905728171984000194425741445815407,0x0000000000000000000000000000000000000f02);

    //         vm.roll(block.number + 32651);
    //         vm.warp(block.timestamp + 150273);
    //         lender_realizeRestakerInterest();

    //         vm.roll(block.number + 38369);
    //         vm.warp(block.timestamp + 387502);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 17085);
    //         vm.warp(block.timestamp + 283490);
    //         oracle_setPriceOracleData(0x00000000000000000000000000000001fffffffE,(0x00000000000000000000000000000000FFFFfFFF, hex"a3edc7b1");

    //         vm.roll(block.number + 33175);
    //         vm.warp(block.timestamp + 114565);
    //         accessControl_grantRole(hex"8fa0e6d4e940ab4d8ed5aa3d1799d92ae4580c499a566cf326359d2f8c2639190c63",0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 153418);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 51642);
    //         vm.warp(block.timestamp + 455740);
    //         capToken_investAll();

    //         vm.roll(block.number + 45626);
    //         vm.warp(block.timestamp + 275394);
    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 9);
    //         vm.warp(block.timestamp + 322310);
    //         accessControl_grantRole(hex"94193014c9b6b1d8263037776f0dd1affe687a4510259762f85409a0f681263792",0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    //         vm.roll(block.number + 32652);
    //         vm.warp(block.timestamp + 3866);
    //         mockERC4626Tester_decreaseYield(1889567281);

    //         vm.roll(block.number + 23640);
    //         vm.warp(block.timestamp + 105767);
    //         stakedCap_permit(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000001fffffffE,115792089237316195423570985008687907853269984665640564039457584007910970861364,39999,71,hex"436861696e6c696e6b416461707465724e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",hex"ecf4b64e554c275b8ce78f01677dfb40b0f3e8e568c883790c6479dda0d4cf2630b989");

    //         vm.roll(block.number + 59502);
    //         vm.warp(block.timestamp + 322347);
    //         property_ltv();

    //         vm.roll(block.number + 5053);
    //         vm.warp(block.timestamp + 390587);
    //         stakedCap_withdraw(115792089237316195423570985008687907853269984665640564039457584007913029639935,0x886D6d1eB8D415b00052828CD6d5B321f072073d,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 16063);
    //         vm.warp(block.timestamp + 38885);
    //         property_repaid_debt_equals_zero_debt();

    //         vm.roll(block.number + 101);
    //         vm.warp(block.timestamp + 23094);
    //         lender_liquidate(115792089237316195423570985008687907853269984665640564039457584007910970861362);

    //         vm.roll(block.number + 23167);
    //         vm.warp(block.timestamp + 222375);
    //         capToken_approve(0x0000000000000000000000000000000000000f02,50186849216440882834365773503793987581223009780705702046838983657059356594816);

    //         vm.roll(block.number + 81);
    //         vm.warp(block.timestamp + 361136);
    //         feeAuction_setMinStartPrice(3210730645604);

    //         vm.roll(block.number + 12232);
    //         vm.warp(block.timestamp + 208886);
    //         doomsday_liquidate(77784623682452896297276757612921833371589091981796380949434520261093249435818);

    //         vm.roll(block.number + 50312);
    //         vm.warp(block.timestamp + 270654);
    //         capToken_realizeInterest(0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 35507);
    //         vm.warp(block.timestamp + 559698);
    //         lender_realizeInterest();

    //         vm.roll(block.number + 14020);
    //         vm.warp(block.timestamp + 205328);
    //         delegation_modifyAgent(0x00000000000000000000000000000002fFffFffD,10925763039789306535304972965395409557844302766103280259662591945254263709314,82378078954299377961602844411987608210834747384499134083242187579854035784489);

    //         vm.roll(block.number + 5140);
    //         vm.warp(block.timestamp + 11);
    //         lender_liquidate(91352034832010926057001582751876410893860910903135406657784615168643518944324);

    //         vm.roll(block.number + 20937);
    //         vm.warp(block.timestamp + 384687);
    //         capToken_investAll();

    //         vm.roll(block.number + 49063);
    //         vm.warp(block.timestamp + 322339);
    //         property_ltv();

    //         vm.roll(block.number + 800);
    //         vm.warp(block.timestamp + 166862);
    //         feeReceiver_setProtocolFeeReceiver(0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 21357);
    //         vm.warp(block.timestamp + 16802);
    //         mockAaveDataProvider_setVariableBorrowRate(60177033920751208088136462691776663159377938138205104852631179029471953460793);

    //         vm.roll(block.number + 14215);
    //         vm.warp(block.timestamp + 315003);
    //         property_staked_cap_value_non_decreasing();

    //         vm.roll(block.number + 14019);
    //         vm.warp(block.timestamp + 311576);
    //         capToken_mint_clamped(56548683243710153011124555768108935019413909561775418266312903711137308197120);

    //         vm.roll(block.number + 254);
    //         vm.warp(block.timestamp + 114026);
    //         feeReceiver_distribute();

    //         vm.roll(block.number + 26049);
    //         vm.warp(block.timestamp + 455741);
    //         mockERC4626Tester_transfer(0xe54a55121A47451c5727ADBAF9b9FC1643477e25,115792089237316195423570985008687907853269984665640564039457584007913129553536);

    //         vm.roll(block.number + 57375);
    //         vm.warp(block.timestamp + 419861);
    //         doomsday_dust_on_redeem();

    //         vm.roll(block.number + 19933);
    //         vm.warp(block.timestamp + 115085);
    //         mockChainlinkPriceFeed_setLatestAnswer_clamped(-57896044618658097711785492504343953926634992332820282019728792003956564819968);

    //         vm.roll(block.number + 1984);
    //         vm.warp(block.timestamp + 82672);
    //         delegation_addAgent(0x00000000000000000000000000000002fFffFffD,0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f,32461938627532109655386966209680202686265168587148184984455650102759133506046,19135459552296935388090104790749168797757153696639071150179259876937001456826);

    //         vm.roll(block.number + 8447);
    //         vm.warp(block.timestamp + 440097);
    //         mockAaveDataProvider_setVariableBorrowRate(122);

    //         vm.roll(block.number + 27404);
    //         vm.warp(block.timestamp + 358061);
    //         feeReceiver_distribute();

    //         vm.roll(block.number + 11942);
    //         vm.warp(block.timestamp + 376096);
    //         lender_borrow(1524785992);

    //         vm.roll(block.number + 33357);
    //         vm.warp(block.timestamp + 379552);
    //         property_health_should_not_change_when_realizeRestakerInterest_is_called();

    //         vm.roll(block.number + 23722);
    //         vm.warp(block.timestamp + 436727);
    //         property_ltv();

    //         vm.roll(block.number + 5053);
    //         vm.warp(block.timestamp + 135921);
    //         oracle_setStaleness(0x0000000000000000000000000000000000000f02,113781589314039280467394802092770976895741664446497382437655313201736093250036);

    //         vm.roll(block.number + 42595);
    //         vm.warp(block.timestamp + 547623);
    //         stakedCap_transfer(0x00000000000000000000000000000000FFFFfFFF,1524785992);

    //         vm.roll(block.number + 4462);
    //         vm.warp(block.timestamp + 521319);
    //         stakedCap_transferFrom(0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000001fffffffE,0);

    //         vm.roll(block.number + 38350);
    //         vm.warp(block.timestamp + 305572);
    //         capToken_setReserve(569);

    //         vm.roll(block.number + 53166);
    //         vm.warp(block.timestamp + 289607);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 12053);
    //         vm.warp(block.timestamp + 19029);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 12053);
    //         vm.warp(block.timestamp + 400981);
    //         switchChainlinkOracle(732);

    //         vm.roll(block.number + 127);
    //         vm.warp(block.timestamp + 436727);
    //         feeAuction_setStartPrice(46013170742117740576639226900063730366259028196008622081111656849683409321696);

    //         vm.roll(block.number + 58783);
    //         vm.warp(block.timestamp + 405856);
    //         doomsday_dust_on_redeem();

    //         vm.roll(block.number + 30132);
    //         vm.warp(block.timestamp + 4177);
    //         property_sum_of_withdrawals();

    //         vm.roll(block.number + 12155);
    //         vm.warp(block.timestamp + 67960);
    //         capToken_setWhitelist(0xD16d567549A2a2a2005aEACf7fB193851603dd70,true);

    //         vm.roll(block.number + 60248);
    //         vm.warp(block.timestamp + 588255);
    //         mockERC4626Tester_setDecimalsOffset(59);

    //         vm.roll(block.number + 53349);
    //         vm.warp(block.timestamp + 115085);
    //         oracle_setBenchmarkRate(0xe54a55121A47451c5727ADBAF9b9FC1643477e25,50044649213945947451802727009396577372587911015090060243527426738178676793393);

    //         vm.roll(block.number + 53011);
    //         vm.warp(block.timestamp + 156190);
    //         lender_borrow_clamped(105401734225248569624449427156461402920370323278279799159960827907367831910641);

    //     }

    // // forge test --match-test test_property_zero_debt_is_borrowing_vbww -vvv
    //     function test_property_zero_debt_is_borrowing_vbww() public {

    //         vm.roll(block.number + 41858);
    //         vm.warp(block.timestamp + 511822);
    //         switchAaveOracle(94429316084656605615998778723570376898378133844088240700784418954738244091335);

    //         vm.roll(block.number + 22238);
    //         vm.warp(block.timestamp + 416749);
    //         lender_cancelLiquidation();

    //         vm.roll(block.number + 5022);
    //         vm.warp(block.timestamp + 2);
    //         mockERC4626Tester_decreaseYield(87491451613419423481861767412035902270526217848459061812387440353582418791167);

    //         vm.roll(block.number + 34872);
    //         vm.warp(block.timestamp + 117472);
    //         delegation_modifyAgent_clamped(90567794898644607698871742117968259459241534293523060441701490148452586206084,115792089237316195423570985008687907853269984665640564039457584007913129639931);

    //         vm.roll(block.number + 48270);
    //         vm.warp(block.timestamp + 45911);
    //         feeAuction_setStartPrice(115792089237316195423570985008687907853269984665640254554447762662844404858881);

    //         vm.roll(block.number + 49026);
    //         vm.warp(block.timestamp + 82670);
    //         mockChainlinkPriceFeed_setLatestAnswer(24904737491998043700481512477015357106195497499428896249910694252867755123228);

    //         vm.roll(block.number + 28730);
    //         vm.warp(block.timestamp + 376219);
    //         mockERC4626Tester_simulateGain(115792089237316195423570985008687907853269984665640564039457584007913129639885);

    //         vm.roll(block.number + 603);
    //         vm.warp(block.timestamp + 350070);
    //         oracle_setMarketOracleData(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38,(0xD6BbDE9174b1CdAa358d2Cf4D57D1a9F7178FBfF, hex"28c62be162c1efdc44454c9815a8cf566ccfb93d6c0c6fd2536fdba961");

    //         vm.roll(block.number + 60054);
    //         vm.warp(block.timestamp + 436727);
    //         switch_asset(115792089237316195423570985008687907853269984665640564039457584007913029622507);

    //         vm.roll(block.number + 38370);
    //         vm.warp(block.timestamp + 322334);
    //         capToken_removeAsset(0x0000000000000000000000000000000000000F0c);

    //         vm.roll(block.number + 31461);
    //         vm.warp(block.timestamp + 236026);
    //         lender_repay(115792089237316195423570985008687907853269984665640564039457584007913129639930);

    //         vm.roll(block.number + 35430);
    //         vm.warp(block.timestamp + 155513);
    //         accessControl_grantAccess(hex"734e554c4e554cb2",0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 48421);
    //         vm.warp(block.timestamp + 140903);
    //         oracle_setRestakerRate(0x8227724C33C1748A42d1C1cD06e21AB8Deb6eB0A,65517724192312670791339229904505511229283099949367566390867124987338414063130);

    //         vm.roll(block.number + 25459);
    //         vm.warp(block.timestamp + 455741);
    //         mockERC4626Tester_deposit(9940406583299850839287211537825243637674794305415380756923033101874973044293,0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);

    //         vm.roll(block.number + 41860);
    //         vm.warp(block.timestamp + 299281);
    //         stakedCap_transfer(0x00000000000000000000000000000001fffffffE,27);

    //         vm.roll(block.number + 30631);
    //         vm.warp(block.timestamp + 357542);
    //         mockERC4626Tester_simulateGain(23203070886045557603674268336741019443080670396168426294314571521884243965334);

    //         vm.roll(block.number + 16061);
    //         vm.warp(block.timestamp + 100000);
    //         accessControl_revokeAccess(hex"4e554c4e554c4e554c4e554c",0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 5022);
    //         vm.warp(block.timestamp + 143809);
    //         mockERC4626Tester_approve(0x00000000000000000000000000000001fffffffE,86552875425837338524576862850198896920093409285987650577781472029470690097675);

    //         vm.roll(block.number + 13784);
    //         vm.warp(block.timestamp + 425572);
    //         property_total_system_collateralization();

    //         vm.roll(block.number + 40598);
    //         vm.warp(block.timestamp + 113488);
    //         mockERC4626Tester_simulateGain(32875071979344592409762619301032965952541202154682707005160610504514426197565);

    //         vm.roll(block.number + 37378);
    //         vm.warp(block.timestamp + 117048);
    //         capToken_redeem_clamped(66919230562231894412829576765417237882886988261758180242087851850759577091645);

    //         vm.roll(block.number + 3600);
    //         vm.warp(block.timestamp + 159643);
    //         delegation_addAgent(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000002fFffFffD,37439836327923360225337895871394760624280537466773280374265222508165906222592,48);

    //         vm.roll(block.number + 32330);
    //         vm.warp(block.timestamp + 569615);
    //         switchActor(115792089237316195423570985008687907853269984665640564039457584007913129639933);

    //         vm.roll(block.number + 46202);
    //         vm.warp(block.timestamp + 34);
    //         oracle_setStaleness(0x00000000000000000000000000000000FFFFfFFF,99999);

    //         vm.roll(block.number + 82);
    //         vm.warp(block.timestamp + 420078);
    //         accessControl_renounceRole(hex"4e4f545f415554484f52495a45444e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",0x0000000000000000000000000000000000000F01);

    //         vm.roll(block.number + 51640);
    //         vm.warp(block.timestamp + 276835);
    //         mockERC4626Tester_simulateGain(14211097524167602802493863989865037497162472790322337168572977);

    //         vm.roll(block.number + 3601);
    //         vm.warp(block.timestamp + 7554);
    //         capToken_setFeeData(0xDA5A5ADC64C8013d334A0DA9e711B364Af7A4C2d,(74765590316438721873018290148271937701985588262012052597345626980822317483264, 115792089237316195423570985008687907853269984665640564039457584007913129639855, 41375297618006374955050063234089756377172308114055575688369838268727278342948, 70178119484554039359183560520838777855181727456028981769742336501032220451930, 847, 112421130013290556312037275319089405478444714642186566594712735527215343907329);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 52772);
    //         vm.warp(block.timestamp + 305996);
    //         stakedCap_deposit(51895644719467792066571894091710869393543355905728171984000194425741445815407,0x0000000000000000000000000000000000000f02);

    //         vm.roll(block.number + 32651);
    //         vm.warp(block.timestamp + 150273);
    //         lender_realizeRestakerInterest();

    //         vm.roll(block.number + 38369);
    //         vm.warp(block.timestamp + 387502);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 17085);
    //         vm.warp(block.timestamp + 283490);
    //         oracle_setPriceOracleData(0x00000000000000000000000000000001fffffffE,(0x00000000000000000000000000000000FFFFfFFF, hex"a3edc7b1");

    //         vm.roll(block.number + 33175);
    //         vm.warp(block.timestamp + 114565);
    //         accessControl_grantRole(hex"8fa0e6d4e940ab4d8ed5aa3d1799d92ae4580c499a566cf326359d2f8c2639190c63",0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 153418);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 51642);
    //         vm.warp(block.timestamp + 455740);
    //         capToken_investAll();

    //         vm.roll(block.number + 45626);
    //         vm.warp(block.timestamp + 275394);
    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 31232);
    //         vm.warp(block.timestamp + 390247);
    //         stakedCap_permit(0x0000000000000000000000000000000000020000,0x1d1499e622D69689cdf9004d05Ec547d650Ff211,105166520322747656188643979101036595448297461692608910467524428314419749133747,115792089237316195423570985008687907853269984665640564039439137263839420088322,37,hex"42f0a2ece8a9f77d83132b75420e44454cbc2635635106a09f59854c982636d40e830405",hex"635553444e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c");

    //         vm.roll(block.number + 5952);
    //         vm.warp(block.timestamp + 49735);
    //         property_no_operation_makes_user_liquidatable();

    //         vm.roll(block.number + 255);
    //         vm.warp(block.timestamp + 135921);
    //         switchActor(40619197993056724595466500495368285758087918070574481742626317773343582659899);

    //         vm.roll(block.number + 12338);
    //         vm.warp(block.timestamp + 490448);
    //         feeReceiver_setProtocolFeeReceiver(0x1aF7f588A501EA2B5bB3feeFA744892aA2CF00e6);

    //         vm.roll(block.number + 24573);
    //         vm.warp(block.timestamp + 419861);
    //         asset_mint(0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7,134422103944139141783022482734694505445);

    //     }

    // // forge test --match-test test_doomsday_manipulate_utilization_rate_6e9w -vvv
    //     function test_doomsday_manipulate_utilization_rate_6e9w() public {

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 39455);
    //         vm.warp(block.timestamp + 311575);
    //         mockNetworkMiddleware_registerVault(0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 11826);
    //         vm.warp(block.timestamp + 322335);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(103341770688910690652700114498011722191660581929354966258250607465273380350457);

    //         vm.roll(block.number + 31460);
    //         vm.warp(block.timestamp + 64);
    //         capToken_removeAsset(0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 45267);
    //         vm.warp(block.timestamp + 510426);
    //         capToken_burn(0x1d1499e622D69689cdf9004d05Ec547d650Ff211,33026036380388846468995296099857229870287056192530636535709815224896729802240,77474550557632893495551472452977347152358378822205064876601557015268799553025,0x00000000000000000000000000000000FFFFfFFF,69876383228922939022944651115856946628174398641990156836326730177986738856418);

    //         vm.roll(block.number + 42275);
    //         vm.warp(block.timestamp + 352544);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 31539);
    //         vm.warp(block.timestamp + 111767);
    //         mockERC4626Tester_transfer(0x00000000000000000000000000000001fffffffE,112227713683026349771627003536414901180348);

    //         vm.roll(block.number + 3661);
    //         vm.warp(block.timestamp + 121286);
    //         mockERC4626Tester_mint(115792089237316195423570985008687907853269984665640564039457584007913129574402,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 32737);
    //         vm.warp(block.timestamp + 73040);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 22699);
    //         vm.warp(block.timestamp + 43815);
    //         property_sum_of_unrealized_interest();

    //         vm.roll(block.number + 255);
    //         vm.warp(block.timestamp + 447588);
    //         property_zero_debt_is_borrowing();

    //         vm.roll(block.number + 561);
    //         vm.warp(block.timestamp + 136394);
    //         feeAuction_setMinStartPrice(23882045632471764707540066905528994016019546766385290738848332946410335530779);

    //         vm.roll(block.number + 36859);
    //         vm.warp(block.timestamp + 566039);
    //         lender_borrow(1524785992);

    //         vm.roll(block.number + 53562);
    //         vm.warp(block.timestamp + 521319);
    //         capToken_divestAll();

    //         vm.roll(block.number + 8123);
    //         vm.warp(block.timestamp + 19029);
    //         lender_addAsset(0x00000000000000000000000000000000FFFFfFFF,0xF62849F9A0B5Bf2913b396098F7c7019b51A820a,0x00000000000000000000000000000001fffffffE,0x00000000000000000000000000000001fffffffE,11868713861016792760287514092222999257883223115650461701361064290414350717869,1524785991);

    //         vm.roll(block.number + 60054);
    //         vm.warp(block.timestamp + 400981);
    //         capToken_mint_clamped(88326532812951261876674767107614202915231832274675550709749739422072412799070);

    //         vm.roll(block.number + 12155);
    //         vm.warp(block.timestamp + 33271);
    //         oracle_setStaleness(0x00000000000000000000000000000002fFffFffD,53275360777494631124286887656662543763296668978902280673726902053613146394012);

    //         vm.roll(block.number + 50499);
    //         vm.warp(block.timestamp + 255);
    //         property_ltv();

    //         vm.roll(block.number + 8447);
    //         vm.warp(block.timestamp + 487078);
    //         lender_removeAsset(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    //         vm.roll(block.number + 23885);
    //         vm.warp(block.timestamp + 487078);
    //         capToken_transferFrom(0x0000000000000000000000000000000000000000,0x00000000000000000000000000000000FFFFfFFF,0);

    //         vm.roll(block.number + 12338);
    //         vm.warp(block.timestamp + 415353);
    //         capToken_divestAll();

    //         vm.roll(block.number + 46422);
    //         vm.warp(block.timestamp + 588255);
    //         property_borrower_cannot_borrow_more_than_ltv();

    //         vm.roll(block.number + 12053);
    //         vm.warp(block.timestamp + 172101);
    //         oracle_setRestakerRate(0x00000000000000000000000000000000FFFFfFFF,1604409886612452221398475686421382145395101027020597852466797389795446277924);

    //         vm.roll(block.number + 9966);
    //         vm.warp(block.timestamp + 277232);
    //         property_total_system_collateralization();

    //         vm.roll(block.number + 11905);
    //         vm.warp(block.timestamp + 376096);
    //         delegation_modifyAgent_clamped(6969551740247971285573395679847639515434855053251938488215897971387708418838,84155008015836471560381008420039632661694879117895187027899772617778063306037);

    //         vm.roll(block.number + 32767);
    //         vm.warp(block.timestamp + 136394);
    //         lender_borrow(1524785991);

    //         vm.roll(block.number + 5054);
    //         vm.warp(block.timestamp + 67960);
    //         capToken_burn_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639934);

    //         vm.roll(block.number + 30256);
    //         vm.warp(block.timestamp + 361136);
    //         doomsday_manipulate_utilization_rate(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //     }

    // // forge test --match-test test_lender_liquidate_q3pp -vvv
    //     function test_lender_liquidate_q3pp() public {

    //         vm.roll(block.number + 41858);
    //         vm.warp(block.timestamp + 511822);
    //         switchAaveOracle(94429316084656605615998778723570376898378133844088240700784418954738244091335);

    //         vm.roll(block.number + 22238);
    //         vm.warp(block.timestamp + 416749);
    //         lender_cancelLiquidation();

    //         vm.roll(block.number + 5022);
    //         vm.warp(block.timestamp + 2);
    //         mockERC4626Tester_decreaseYield(87491451613419423481861767412035902270526217848459061812387440353582418791167);

    //         vm.roll(block.number + 34872);
    //         vm.warp(block.timestamp + 117472);
    //         delegation_modifyAgent_clamped(90567794898644607698871742117968259459241534293523060441701490148452586206084,115792089237316195423570985008687907853269984665640564039457584007913129639931);

    //         vm.roll(block.number + 48270);
    //         vm.warp(block.timestamp + 45911);
    //         feeAuction_setStartPrice(115792089237316195423570985008687907853269984665640254554447762662844404858881);

    //         vm.roll(block.number + 49026);
    //         vm.warp(block.timestamp + 82670);
    //         mockChainlinkPriceFeed_setLatestAnswer(24904737491998043700481512477015357106195497499428896249910694252867755123228);

    //         vm.roll(block.number + 28730);
    //         vm.warp(block.timestamp + 376219);
    //         mockERC4626Tester_simulateGain(115792089237316195423570985008687907853269984665640564039457584007913129639885);

    //         vm.roll(block.number + 603);
    //         vm.warp(block.timestamp + 350070);
    //         oracle_setMarketOracleData(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38,(0xD6BbDE9174b1CdAa358d2Cf4D57D1a9F7178FBfF, hex"28c62be162c1efdc44454c9815a8cf566ccfb93d6c0c6fd2536fdba961");

    //         vm.roll(block.number + 60054);
    //         vm.warp(block.timestamp + 436727);
    //         switch_asset(115792089237316195423570985008687907853269984665640564039457584007913029622507);

    //         vm.roll(block.number + 38370);
    //         vm.warp(block.timestamp + 322334);
    //         capToken_removeAsset(0x0000000000000000000000000000000000000F0c);

    //         vm.roll(block.number + 31461);
    //         vm.warp(block.timestamp + 236026);
    //         lender_repay(115792089237316195423570985008687907853269984665640564039457584007913129639930);

    //         vm.roll(block.number + 35430);
    //         vm.warp(block.timestamp + 155513);
    //         accessControl_grantAccess(hex"734e554c4e554cb2",0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 48421);
    //         vm.warp(block.timestamp + 140903);
    //         oracle_setRestakerRate(0x8227724C33C1748A42d1C1cD06e21AB8Deb6eB0A,65517724192312670791339229904505511229283099949367566390867124987338414063130);

    //         vm.roll(block.number + 25459);
    //         vm.warp(block.timestamp + 455741);
    //         mockERC4626Tester_deposit(9940406583299850839287211537825243637674794305415380756923033101874973044293,0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);

    //         vm.roll(block.number + 41860);
    //         vm.warp(block.timestamp + 299281);
    //         stakedCap_transfer(0x00000000000000000000000000000001fffffffE,27);

    //         vm.roll(block.number + 30631);
    //         vm.warp(block.timestamp + 357542);
    //         mockERC4626Tester_simulateGain(23203070886045557603674268336741019443080670396168426294314571521884243965334);

    //         vm.roll(block.number + 16061);
    //         vm.warp(block.timestamp + 100000);
    //         accessControl_revokeAccess(hex"4e554c4e554c4e554c4e554c",0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000002fFffFffD);

    //         vm.roll(block.number + 5022);
    //         vm.warp(block.timestamp + 143809);
    //         mockERC4626Tester_approve(0x00000000000000000000000000000001fffffffE,86552875425837338524576862850198896920093409285987650577781472029470690097675);

    //         vm.roll(block.number + 13784);
    //         vm.warp(block.timestamp + 425572);
    //         property_total_system_collateralization();

    //         vm.roll(block.number + 40598);
    //         vm.warp(block.timestamp + 113488);
    //         mockERC4626Tester_simulateGain(32875071979344592409762619301032965952541202154682707005160610504514426197565);

    //         vm.roll(block.number + 37378);
    //         vm.warp(block.timestamp + 117048);
    //         capToken_redeem_clamped(66919230562231894412829576765417237882886988261758180242087851850759577091645);

    //         vm.roll(block.number + 3600);
    //         vm.warp(block.timestamp + 159643);
    //         delegation_addAgent(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000002fFffFffD,37439836327923360225337895871394760624280537466773280374265222508165906222592,48);

    //         vm.roll(block.number + 32330);
    //         vm.warp(block.timestamp + 569615);
    //         switchActor(115792089237316195423570985008687907853269984665640564039457584007913129639933);

    //         vm.roll(block.number + 46202);
    //         vm.warp(block.timestamp + 34);
    //         oracle_setStaleness(0x00000000000000000000000000000000FFFFfFFF,99999);

    //         vm.roll(block.number + 82);
    //         vm.warp(block.timestamp + 420078);
    //         accessControl_renounceRole(hex"4e4f545f415554484f52495a45444e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",0x0000000000000000000000000000000000000F01);

    //         vm.roll(block.number + 51640);
    //         vm.warp(block.timestamp + 276835);
    //         mockERC4626Tester_simulateGain(14211097524167602802493863989865037497162472790322337168572977);

    //         vm.roll(block.number + 3601);
    //         vm.warp(block.timestamp + 7554);
    //         capToken_setFeeData(0xDA5A5ADC64C8013d334A0DA9e711B364Af7A4C2d,(74765590316438721873018290148271937701985588262012052597345626980822317483264, 115792089237316195423570985008687907853269984665640564039457584007913129639855, 41375297618006374955050063234089756377172308114055575688369838268727278342948, 70178119484554039359183560520838777855181727456028981769742336501032220451930, 847, 112421130013290556312037275319089405478444714642186566594712735527215343907329);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 36723);
    //         vm.warp(block.timestamp + 311699);
    //         mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 43649);
    //         vm.warp(block.timestamp + 352545);
    //         capToken_mint_clamped(12000000000000000000001);

    //         vm.roll(block.number + 52772);
    //         vm.warp(block.timestamp + 305996);
    //         stakedCap_deposit(51895644719467792066571894091710869393543355905728171984000194425741445815407,0x0000000000000000000000000000000000000f02);

    //         vm.roll(block.number + 32651);
    //         vm.warp(block.timestamp + 150273);
    //         lender_realizeRestakerInterest();

    //         vm.roll(block.number + 38369);
    //         vm.warp(block.timestamp + 387502);
    //         lender_cancelLiquidation_clamped();

    //         vm.roll(block.number + 17085);
    //         vm.warp(block.timestamp + 283490);
    //         oracle_setPriceOracleData(0x00000000000000000000000000000001fffffffE,(0x00000000000000000000000000000000FFFFfFFF, hex"a3edc7b1");

    //         vm.roll(block.number + 33175);
    //         vm.warp(block.timestamp + 114565);
    //         accessControl_grantRole(hex"8fa0e6d4e940ab4d8ed5aa3d1799d92ae4580c499a566cf326359d2f8c2639190c63",0x00000000000000000000000000000000FFFFfFFF);

    //         vm.roll(block.number + 28126);
    //         vm.warp(block.timestamp + 153418);
    //         property_borrowed_asset_value();

    //         vm.roll(block.number + 51642);
    //         vm.warp(block.timestamp + 455740);
    //         capToken_investAll();

    //         vm.roll(block.number + 45626);
    //         vm.warp(block.timestamp + 275394);
    //         lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //         vm.roll(block.number + 9);
    //         vm.warp(block.timestamp + 322310);
    //         accessControl_grantRole(hex"94193014c9b6b1d8263037776f0dd1affe687a4510259762f85409a0f681263792",0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    //         vm.roll(block.number + 32652);
    //         vm.warp(block.timestamp + 3866);
    //         mockERC4626Tester_decreaseYield(1889567281);

    //         vm.roll(block.number + 23640);
    //         vm.warp(block.timestamp + 105767);
    //         stakedCap_permit(0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000001fffffffE,115792089237316195423570985008687907853269984665640564039457584007910970861364,39999,71,hex"436861696e6c696e6b416461707465724e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",hex"ecf4b64e554c275b8ce78f01677dfb40b0f3e8e568c883790c6479dda0d4cf2630b989");

    //         vm.roll(block.number + 59502);
    //         vm.warp(block.timestamp + 322347);
    //         property_ltv();

    //         vm.roll(block.number + 5053);
    //         vm.warp(block.timestamp + 390587);
    //         stakedCap_withdraw(115792089237316195423570985008687907853269984665640564039457584007913029639935,0x886D6d1eB8D415b00052828CD6d5B321f072073d,0x00000000000000000000000000000001fffffffE);

    //         vm.roll(block.number + 16063);
    //         vm.warp(block.timestamp + 38885);
    //         property_repaid_debt_equals_zero_debt();

    //         vm.roll(block.number + 101);
    //         vm.warp(block.timestamp + 23094);
    //         lender_liquidate(115792089237316195423570985008687907853269984665640564039457584007910970861362);

    //         vm.roll(block.number + 23167);
    //         vm.warp(block.timestamp + 222375);
    //         capToken_approve(0x0000000000000000000000000000000000000f02,50186849216440882834365773503793987581223009780705702046838983657059356594816);

    //         vm.roll(block.number + 20236);
    //         vm.warp(block.timestamp + 263864);
    //         switchActor(84319672218320696189650618947853578043834655284055450833793476725750752932995);

    //         vm.roll(block.number + 55736);
    //         vm.warp(block.timestamp + 86400);
    //         switchDebtToken(4271788395197041876509671405636824930653082506246531648131019223959341290825);

    //         vm.roll(block.number + 32855);
    //         vm.warp(block.timestamp + 352542);
    //         switchChainlinkOracle(1299631);

    //         vm.roll(block.number + 32552);
    //         vm.warp(block.timestamp + 540357);
    //         property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token();

    //         vm.roll(block.number + 31202);
    //         vm.warp(block.timestamp + 324839);
    //         property_vault_solvency_assets();

    //         vm.roll(block.number + 82);
    //         vm.warp(block.timestamp + 416271);
    //         lender_addAsset(0x00000000000000000000000000000002fFffFffD,0x92a6649Fdcc044DA968d94202465578a9371C7b1,0x00000000000000000000000000000002fFffFffD,0x00000000000000000000000000000001fffffffE,40,115792089237316195423570985008687907853269984665640564039457584007913129639920);

    //         vm.roll(block.number + 25399);
    //         vm.warp(block.timestamp + 168957);
    //         property_fractional_reserve_vault_has_reserve_amount_of_underlying_asset();

    //         vm.roll(block.number + 35265);
    //         vm.warp(block.timestamp + 65534);
    //         capToken_addAsset();

    //         vm.roll(block.number + 1001);
    //         vm.warp(block.timestamp + 7373);
    //         asset_mint(0x0000000000000000000000000000000000000F03,66678142479726504176202100221389921552);

    //         vm.roll(block.number + 800);
    //         vm.warp(block.timestamp + 136777);
    //         lender_initiateLiquidation();

    //         vm.roll(block.number + 54774);
    //         vm.warp(block.timestamp + 327860);
    //         stakedCap_transferFrom(0x886D6d1eB8D415b00052828CD6d5B321f072073d,0x0000000000000000000000000000000000000f05,100014445);

    //         vm.roll(block.number + 60364);
    //         vm.warp(block.timestamp + 448552);
    //         capToken_divestAll();

    //         vm.roll(block.number + 58183);
    //         vm.warp(block.timestamp + 228130);
    //         capToken_redeem_clamped(99999999999999999999999999);

    //         vm.roll(block.number + 50591);
    //         vm.warp(block.timestamp + 322366);
    //         capToken_divestAll();

    //         vm.roll(block.number + 16063);
    //         vm.warp(block.timestamp + 487078);
    //         capToken_unpauseProtocol();

    //         vm.roll(block.number + 4990);
    //         vm.warp(block.timestamp + 322373);
    //         capToken_removeAsset(0x0000000000000000000000000000000000020000);

    //         vm.roll(block.number + 2512);
    //         vm.warp(block.timestamp + 136778);
    //         mockChainlinkPriceFeed_setLatestAnswer_clamped(28300637623896771941709217596652005582743766817181502227070143654330710848769);

    //         vm.roll(block.number + 2511);
    //         vm.warp(block.timestamp + 416271);
    //         property_delegated_value_greater_than_borrowed_value();

    //         vm.roll(block.number + 4128);
    //         vm.warp(block.timestamp + 99);
    //         property_fractional_reserve_vault_has_reserve_amount_of_underlying_asset();

    //         vm.roll(block.number + 31460);
    //         vm.warp(block.timestamp + 547623);
    //         delegation_setLtvBuffer(4339175913997661546349579291793116856624438744825713635498455186496959483);

    //         vm.roll(block.number + 10521);
    //         vm.warp(block.timestamp + 199710);
    //         property_no_operation_makes_user_liquidatable();

    //         vm.roll(block.number + 40599);
    //         vm.warp(block.timestamp + 19029);
    //         property_sum_of_withdrawals();

    //         vm.roll(block.number + 4929);
    //         vm.warp(block.timestamp + 195580);
    //         lender_cancelLiquidation();

    //         vm.roll(block.number + 6372);
    //         vm.warp(block.timestamp + 318774);
    //         stakedCap_permit(0xe54a55121A47451c5727ADBAF9b9FC1643477e25,0x212224D2F2d262cd093eE13240ca4873fcCBbA3C,48871429319303466548125115479446274902690738504501947070829642578886829602240,115792089237316195423570985008687907853269984665640564039457584007913129639900,114,hex"496e76616c69644275726e416d6f756e7428293b4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",hex"426ce5894150e3a3a7c8d0599574c176eeab4b05bad96110ab515ffe6245f1a3");

    //         vm.roll(block.number + 19304);
    //         vm.warp(block.timestamp + 540358);
    //         property_debt_token_balance_gte_total_vault_debt();

    //         vm.roll(block.number + 33357);
    //         vm.warp(block.timestamp + 395200);
    //         capToken_mint_clamped(652001293);

    //         vm.roll(block.number + 22699);
    //         vm.warp(block.timestamp + 166862);
    //         lender_initiateLiquidation_clamped();

    //         vm.roll(block.number + 44696);
    //         vm.warp(block.timestamp + 452806);
    //         lender_realizeInterest();

    //         vm.roll(block.number + 20237);
    //         vm.warp(block.timestamp + 531977);
    //         lender_initiateLiquidation_clamped();

    //         vm.roll(block.number + 58106);
    //         vm.warp(block.timestamp + 7993);
    //         add_new_vault();

    //         vm.roll(block.number + 45261);
    //         vm.warp(block.timestamp + 117472);
    //         capToken_pauseProtocol();

    //         vm.roll(block.number + 53011);
    //         vm.warp(block.timestamp + 205816);
    //         property_utilization_ratio_never_greater_than_1e27();

    //         vm.roll(block.number + 60364);
    //         vm.warp(block.timestamp + 463588);
    //         stakedCap_approve(0x0000000000000000000000000000000000000000,6229420587986584004948174139341158331454353103101795561763766619835141470720);

    //         vm.roll(block.number + 6234);
    //         vm.warp(block.timestamp + 82671);
    //         stakedCap_transferFrom(0x3Cff5E7eBecb676c3Cb602D0ef2d46710b88854E,0x00000000000000000000000000000001fffffffE,32169690217161784883955862442891440183354993550477856192686699548216942073856);

    //         vm.roll(block.number + 53011);
    //         vm.warp(block.timestamp + 117472);
    //         property_sum_of_deposits();

    //         vm.roll(block.number + 59982);
    //         vm.warp(block.timestamp + 19029);
    //         oracle_setRestakerRate(0x3C4293F66941ECa00f4950C10d4255d5c271bAeF,1524785992);

    //         vm.roll(block.number + 22909);
    //         vm.warp(block.timestamp + 31594);
    //         property_repaid_debt_equals_zero_debt();

    //         vm.roll(block.number + 53451);
    //         vm.warp(block.timestamp + 526194);
    //         property_health_should_not_change_when_realizeRestakerInterest_is_called();

    //         vm.roll(block.number + 4462);
    //         vm.warp(block.timestamp + 115085);
    //         lender_pauseAsset(true);

    //         vm.roll(block.number + 59981);
    //         vm.warp(block.timestamp + 404997);
    //         capToken_unpauseProtocol();

    //         vm.roll(block.number + 58783);
    //         vm.warp(block.timestamp + 73040);
    //         capToken_transferFrom(0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000000FFFFfFFF,115792089237316195423570984908687907853269984665640564039457584007913129639937);

    //     }
}
