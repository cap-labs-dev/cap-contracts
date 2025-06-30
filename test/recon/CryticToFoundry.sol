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
    // NOTE: acknowledged by team that this is a real break, but fix will be delayed because admin can just realize interest before changing restaker rate to fix it
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
    // NOTE: valid, need to discover the root cause
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

    // forge test --match-test test_doomsday_maxBorrow_14 -vvv
    // NOTE: looks like a real break, maxBorrows is nonzero after borrowing max
    function test_doomsday_maxBorrow_14() public {
        switch_asset(1);

        capToken_mint_clamped(14710106794859);

        switchChainlinkOracle(1);

        mockChainlinkPriceFeed_setLatestAnswer_clamped(0);
        console2.log("latest answer %e", mockChainlinkPriceFeed.latestAnswer());

        doomsday_maxBorrow();
    }

    // forge test --match-test test_doomsday_debt_token_solvency_4 -vvv
    // NOTE: real break, but minimal max insolvency of 1 wei
    function test_doomsday_debt_token_solvency_4() public {
        capToken_mint_clamped(10030351031);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        vm.warp(block.timestamp + 3);

        vm.roll(block.number + 1);

        switchActor(1);

        capToken_mint_clamped(10000217616);

        lender_borrow_clamped(100077341);

        doomsday_debt_token_solvency();
    }

    // forge test --match-test test_capToken_burn_clamped_6 -vvv
    // NOTE: real break, setting high reserves can prevent burning
    function test_capToken_burn_clamped_6() public {
        asset_mint(0xe916cadb12C49389E487eB1e8194B1459b29B0eC, 1);

        capToken_mint_clamped(20002893847);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        capToken_setReserve(10011737767);

        capToken_burn_clamped(10000256330);
    }

    // forge test --match-test test_capToken_burn_8 -vvv
    // NOTE: same as above, but with unclamped handler
    function test_capToken_burn_8() public {
        asset_mint(0xe916cadb12C49389E487eB1e8194B1459b29B0eC, 1);

        capToken_mint_clamped(20017387312);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        add_new_vault();

        capToken_setFractionalReserveVault();

        lender_repay(1);

        capToken_investAll();

        capToken_burn(10011616360, 0, 0);
    }

    /// === Newest Issues === ///

    // forge test --match-test test_property_no_agent_borrowing_current_utilization_rate_should_be_zero_0 -vvv
    function test_property_no_agent_borrowing_current_utilization_rate_should_be_zero_0() public {
        lender_borrow(100218131);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        lender_repay(100563958);

        property_no_agent_borrowing_current_utilization_rate_should_be_zero();
    }
}
