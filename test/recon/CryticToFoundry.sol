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

    // forge test --match-test test_capToken_redeem_clamped_6 -vvv
    // NOTE: minting unbacked shares causes underflow revert in redemeptions, might just need to remove this from mockERC4626Tester
    // TODO: determine if minting unbacked shares is realisitc behavior
    function test_capToken_redeem_clamped_6() public {
        capToken_mint_clamped(10000037441);

        add_new_vault();

        capToken_setFractionalReserveVault_clamped();

        capToken_investAll_clamped();

        // decreases the PPFS
        // is this realistic for yearn V3 though? is there anything in how losses are realized that would cause this?
        // seems like it is because the PPS is decreased for all users when a loss is realized
        mockERC4626Tester_mintUnbackedShares(100003377823040994724, 0x0000000000000000000000000000000000000000);

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

        capToken_setFractionalReserveVault_clamped();

        capToken_investAll_clamped();

        mockERC4626Tester_simulateLoss(1);

        add_new_vault();

        property_vault_solvency_assets();
    }

    // forge test --match-test test_lender_repay_6 -vvv
    function test_lender_repay_6() public {
        capToken_mint_clamped(10002011355);

        lender_borrow_clamped(100051063);

        oracle_setRestakerRate(
            0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,
            1157449494152887941185278230451771113777492868836762663430031328785281
        );

        lender_repay(0);
    }

    // forge test --match-test test_lender_realizeRestakerInterest_7 -vvv
    // TODO: come back to this, need to figure out why tracking delegation balance is off even though the transfer of the asset to it is successful
    function test_lender_realizeRestakerInterest_7() public {
        oracle_setRestakerRate(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 1679060376);

        capToken_mint_clamped(106481131726877242408);

        lender_borrow_clamped(105848193758379280936);

        vm.warp(block.timestamp + 177294);

        vm.roll(block.number + 1);

        lender_realizeRestakerInterest();
    }
}
