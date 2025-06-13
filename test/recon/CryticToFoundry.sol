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
        mockNetworkMiddleware_setMockCollateralByVault(0x796f2974e3C1af763252512dd6d521E9E984726C, 10002564536);
        property_borrowed_asset_value();
    }

    function test_fractional_reserve_loss() public {
        // 1. Create a new vault
        add_new_vault();

        // 2. Set up the fractional reserve vault
        capToken_setFractionalReserveVault();

        // 3. Mint CapToken with the asset
        uint256 mintAmount = 1e18; // 1 token with 18 decimals
        capToken_mint(_getAsset(), mintAmount, 0, _getActor(), block.timestamp + 1 days);

        // 4. Invest all assets in the CapToken
        capToken_investAll();

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

    // forge test --match-test test_capToken_redeem_clamped_6 -vvv
    // NOTE: issue is because of implementation of ERC4626Tester, need to determine best way to fix behavior
    // TODO: determine best way to fix ERC4626Tester behavior
    function test_capToken_redeem_clamped_6() public {
        capToken_mint_clamped(10000037441);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        // issue is because shares in withdraw calculated by previewWithdraw now get increased but user balance doesn't
        // most likely fix would be to rebase shares for all users when unbacked shares are minted
        // or just make it so that users can only withdraw up to the maxWithdraw amount
        mockERC4626Tester_mintUnbackedShares(100003377823040994724, 0x0000000000000000000000000000000000000000);
        // mockERC4626Tester_simulateLoss(200);

        capToken_redeem_clamped(1);
    }

    // forge test --match-test test_lender_liquidate_2 -vvv
    // NOTE: Liquidation did not improve health factor, try to invest
    function test_lender_liquidate_2() public {
        capToken_mint_clamped(6505424303794);
        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        switchChainlinkOracle(14211097524167602802493863989865037497162472790322337168572978);
        mockChainlinkPriceFeed_setLatestAnswer(2713282178368992834);
        lender_liquidate(1);
    }

    // forge test --match-test test_property_vault_solvency_assets_12 -vvv
    function test_property_vault_solvency_assets_12() public {
        capToken_mint_clamped(10001099720);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_simulateLoss(1);

        add_new_vault();

        property_vault_solvency_assets();
    }

    // forge test --match-test test_doomsday_repay_8pb4 -vvv
    function test_doomsday_repay_8pb4() public {
        capToken_mint_clamped(10000667218);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        capToken_pauseProtocol();

        doomsday_repay(1);
    }

    // forge test --match-test test_capToken_burn_clamped_uuhn -vvv
    function test_capToken_burn_clamped_uuhn() public {
        switch_asset(1);

        capToken_mint_clamped(2);

        asset_mint(0x000000000000000000000000000000000000bEEF, 1);

        capToken_burn_clamped(10000683817);
    }

    // forge test --match-test test_lender_realizeInterest_92dr -vvv
    function test_lender_realizeInterest_92dr() public {
        capToken_mint_clamped(10001031987);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 6320941977990957197644574);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        vm.warp(block.timestamp + 1);

        vm.roll(block.number + 1);

        doomsday_repay(1);

        lender_realizeInterest();
    }

    // forge test --match-test test_doomsday_liquidate_h1m4 -vvv
    function test_doomsday_liquidate_h1m4() public {
        doomsday_liquidate(1);
    }

    // forge test --match-test test_lender_repay_66ot -vvv
    function test_lender_repay_66ot() public {
        capToken_mint_clamped(10000257342);

        switchChainlinkOracle(3);

        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 316797274992429809111462774);

        lender_borrow(100000001, 0x00000000000000000000000000000000DeaDBeef);

        mockChainlinkPriceFeed_setLatestAnswer(1157931559455332453960847362481255236276452787816647258012);

        vm.warp(block.timestamp + 1);

        vm.roll(block.number + 1);

        lender_repay(0);
    }

    // forge test --match-test test_lender_borrow_clamped_22er -vvv
    // function test_lender_borrow_clamped_22er() public {

    //     vm.roll(block.number + 36723);
    //     vm.warp(block.timestamp + 311699);
    //     mockNetworkMiddleware_setMockSlashableCollateralByVault(53502540585222975478199632749217283793864113140416536062295354888833147494184);

    //     vm.roll(block.number + 43649);
    //     vm.warp(block.timestamp + 352545);
    //     capToken_mint_clamped(12000000000000000000001);

    //     vm.roll(block.number + 39455);
    //     vm.warp(block.timestamp + 311575);
    //     mockNetworkMiddleware_registerVault(0x00000000000000000000000000000000FFFFfFFF);

    //     vm.roll(block.number + 11826);
    //     vm.warp(block.timestamp + 322335);
    //     mockNetworkMiddleware_setMockSlashableCollateralByVault(103341770688910690652700114498011722191660581929354966258250607465273380350457);

    //     vm.roll(block.number + 31460);
    //     vm.warp(block.timestamp + 64);
    //     capToken_removeAsset(0x00000000000000000000000000000002fFffFffD);

    //     vm.roll(block.number + 9842);
    //     vm.warp(block.timestamp + 322335);
    //     capToken_divestAll(0x00000000000000000000000000000000FFFFfFFF);

    //     vm.roll(block.number + 49251);
    //     vm.warp(block.timestamp + 503602);
    //     lender_cancelLiquidation(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);

    //     vm.roll(block.number + 35571);
    //     vm.warp(block.timestamp + 64);
    //     capToken_rescueERC20(0x00000000000000000000000000000000FFFFfFFF,0x00000000000000000000000000000000FFFFfFFF);

    //     vm.roll(block.number + 47075);
    //     vm.warp(block.timestamp + 436727);
    //     lender_realizeRestakerInterest(0xF62849F9A0B5Bf2913b396098F7c7019b51A820a,0x00000000000000000000000000000000FFFFfFFF);

    //     vm.roll(block.number + 5022);
    //     vm.warp(block.timestamp + 425633);
    //     mockNetworkMiddleware_setMockSlashableCollateral(62661634916210430187291605662829386261351947169964313162115263642735077475654);

    //     vm.roll(block.number + 6068);
    //     vm.warp(block.timestamp + 322375);
    //     lender_cancelLiquidation_clamped();

    //     vm.roll(block.number + 14891);
    //     vm.warp(block.timestamp + 36);
    //     asset_approve(0x00000000000000000000000000000002fFffFffD,100000000000001);

    // }

    // forge test --match-test test_property_utilization_ratio_10zx -vvv
    // function test_property_utilization_ratio_10zx() public {

    //     capToken_mint_clamped(10000421606);

    //     lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //     mockNetworkMiddleware_setMockCollateralByVault(0xe8dc788818033232EF9772CB2e6622F1Ec8bc840,0);

    //     lender_liquidate(421660);

    //     property_utilization_ratio();

    // }

    // forge test --match-test test_lender_liquidate_6pvg -vvv
    function test_lender_liquidate_6pvg() public {
        capToken_mint_clamped(10000638121);

        lender_borrow_clamped(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        mockNetworkMiddleware_setMockCollateralByVault(0xe8dc788818033232EF9772CB2e6622F1Ec8bc840, 0);

        lender_liquidate(1);
    }

    // forge test --match-test test_lender_borrow_850x -vvv
    function test_lender_borrow_850x() public {
        capToken_mint_clamped(10003543734);

        capToken_pauseAsset(0xD16d567549A2a2a2005aEACf7fB193851603dd70);

        lender_borrow(100018335, 0x00000000000000000000000000000000DeaDBeef);
    }
}
