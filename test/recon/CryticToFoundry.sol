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

    // forge test --match-test test_doomsday_liquidate_1 -vvv
    // NOTE: looks like a depeg can cause liquidation to fail
    function test_doomsday_liquidate_1() public {
        capToken_mint_clamped(76546915659384565102);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        asset_approve(0x15cF58144EF33af1e14b5208015d11F9143E27b9, 0);

        switchChainlinkOracle(3);

        // sets the price to 8.5016866e7
        mockChainlinkPriceFeed_setLatestAnswer_clamped(-158910016361134981458467509623070);

        doomsday_liquidate(1);
    }

    // forge test --match-test test_property_no_agent_borrowing_total_debt_and_utilization_rate_should_be_zero_13 -vvv
    // NOTE: seems like this would mess up the rate calculation in VaultAdapter, causing a 0 rate if all agents have repaid
    // TODO: investigate further
    function test_property_no_agent_borrowing_total_debt_and_utilization_rate_should_be_zero_13() public {
        capToken_mint_clamped(10155906430);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        vm.warp(block.timestamp + 1);

        vm.roll(block.number + 1);

        lender_repay(11578722538);

        switch_asset(507841201531444);

        lender_removeAsset(0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758);

        switch_asset(51100855422138231202198802307432956527994435);

        // need a way to query VaultAdapter rate
        // uint256 rate = oracle.rate(address(capToken), _getAsset());

        // utilizationIndex 1e27
        property_no_agent_borrowing_current_utilization_rate_should_be_zero();
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

    // forge test --match-test test_doomsday_compound_vs_linear_accumulation_16 -vvv
    // NOTE: realizing interest partway through a time period increases the unrealized interest
    function test_doomsday_compound_vs_linear_accumulation_16() public {
        switch_asset(0);

        capToken_mint_clamped(122454342);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 1600783476099645525198470);

        doomsday_compound_vs_linear_accumulation(81);
    }

    /// === Newest Issues === ///
}
