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
    // NOTE: this no longer fails with the check for user allowance included because it was reverting before the cUSD was burned for the user
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

    // forge test --match-test test_capToken_redeem_0 -vvv
    // NOTE: same issue as above
    function test_capToken_redeem_0() public {
        capToken_mint_clamped(10001211781);
        add_new_vault();
        capToken_setFractionalReserveVault();
        capToken_investAll();
        mockERC4626Tester_mintUnbackedShares(100030086342248146205, address(0));
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

    // forge test --match-test test_capToken_divestAll_6 -vvv
    // NOTE: same issue as test_capToken_redeem_clamped_6 related to MockERC4626Tester
    function test_capToken_divestAll_6() public {
        capToken_mint_clamped(10006397379);

        add_new_vault();

        capToken_setFractionalReserveVault();

        capToken_investAll();

        mockERC4626Tester_mintUnbackedShares(
            11587865888101675086496162918830780777506068448851247110970105602638,
            0x796f2974e3C1af763252512dd6d521E9E984726C
        );

        capToken_divestAll();
    }

    // forge test --match-test test_lender_repay_9 -vvv
    // TODO: figure out a way to handle this without overclamping the oracle
    function test_lender_repay_9() public {
        capToken_mint_clamped(10008018367);

        lender_borrow_clamped(100017430);

        oracle_setRestakerRate(
            0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,
            1160841625282391919459699258693856538360040157823143612386102239793921
        );

        lender_repay(1);
    }

    /// === Newest Issues === ///
}
