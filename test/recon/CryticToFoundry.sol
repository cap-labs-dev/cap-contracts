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
    // NOTE: Liquidation did not improve health factor, related to oracle price
    // valid break but is the case when bad debt is created after a liquidation: https://github.com/Recon-Fuzz/cap-invariants/issues/32
    function test_lender_liquidate_0() public {
        switchActor(1);

        capToken_mint_clamped(10005653326);

        lender_borrow(501317817);

        switchChainlinkOracle(2);

        mockChainlinkPriceFeed_setLatestAnswer(49869528211447337507581);

        (,, uint256 totalDebt,,,) = _getAgentParams(_getActor());
        console2.log("totalDebt", totalDebt);
        uint256 coverage = delegation.coverage(_getActor());
        console2.log("coverage", coverage);

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

    // forge test --match-test test_lender_realizeRestakerInterest_8 -vvv
    // NOTE: if interest isn't realized after the rate is changed for a user and the fractional reserve vault is set
    // it can cause vault debt increase != asset decrease in realizeRestakerInterest, added as a gotcha here: https://github.com/Recon-Fuzz/cap-invariants/issues/22#issuecomment-3025077296
    function test_lender_realizeRestakerInterest_8() public {
        lender_borrow_clamped(100009864);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 315727571370246195585225815);

        add_new_vault();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        capToken_setFractionalReserveVault();

        // @audit realizing interest here resolves the issue
        // lender_realizeRestakerInterest();

        capToken_investAll();

        lender_realizeRestakerInterest();
    }

    // forge test --match-test test_capToken_redeem_11 -vvv
    // NOTE: this fails because of loss from fractional reserve vault, acknowledged as expected by team
    function test_capToken_redeem_11() public {
        add_new_vault();
        capToken_setFractionalReserveVault();
        capToken_investAll();
        mockERC4626Tester_decreaseYield(10000);
        capToken_approve(0x92a6649Fdcc044DA968d94202465578a9371C7b1, 1);
        capToken_redeem(1, new uint256[](1), address(0), 0);
    }

    // forge test --match-test test_capToken_redeem_clamped_14 -vvv
    // NOTE: fails for same reason as test_capToken_redeem_11
    function test_capToken_redeem_clamped_14() public {
        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_decreaseYield(10000);

        capToken_approve(0x92a6649Fdcc044DA968d94202465578a9371C7b1, 1);

        capToken_redeem_clamped(1);
    }

    // forge test --match-test test_doomsday_maxBorrow_5 -vvv
    // NOTE: still not resolved after latest changes in commit 1371276e3d553c2feac20c3e93308aee65d1ad97
    function test_doomsday_maxBorrow_5() public {
        switch_asset(1072445895501);

        capToken_mint_clamped(125148553275);

        lender_borrow(100077341);

        vm.warp(block.timestamp + 8);

        vm.roll(block.number + 1);

        doomsday_maxBorrow();
    }

    // forge test --match-test test_capToken_burn_clamped_4 -vvv
    // NOTE: loss on fractional reserve vault causes burn to fail, expected behavior
    function test_capToken_burn_clamped_4() public {
        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_decreaseYield(10000);

        capToken_burn_clamped(10001839867);
    }

    /// === Newest Issues === ///
}
