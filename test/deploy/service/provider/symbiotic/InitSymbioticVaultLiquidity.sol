// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticUtils } from "../../../../../contracts/deploy/utils/SymbioticUtils.sol";
import { MockERC20 } from "../../../../mocks/MockERC20.sol";
import { TestEnvConfig, TestUsersConfig } from "../../../interfaces/TestDeployConfig.sol";

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { InfraConfig } from "../../../interfaces/TestDeployConfig.sol";
import { TimeUtils } from "../../../utils/TimeUtils.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract InitSymbioticVaultLiquidity is Test, SymbioticUtils, TimeUtils {
    function _initSymbioticVaultsLiquidity(TestEnvConfig memory env, uint256 amountNoDecimals) internal {
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            address vault = env.symbiotic.vaults[i];
            _initSymbioticVaultLiquidityForAgent(env.testUsers, vault, amountNoDecimals);
        }

        _timeTravel(28 days);
    }

    function _initSymbioticVaultLiquidityForAgent(
        TestUsersConfig memory testUsers,
        address vault,
        uint256 amountNoDecimals
    ) internal returns (uint256 depositedAmount, uint256 mintedShares) {
        address collateral = IVault(vault).collateral();
        uint256 amount = amountNoDecimals * 10 ** MockERC20(collateral).decimals();

        for (uint256 i = 0; i < testUsers.restakers.length; i++) {
            address restaker = testUsers.restakers[i];
            (uint256 restakerDepositedAmount, uint256 restakerMintedShares) =
                _symbioticMintAndStakeInVault(vault, restaker, amount);
            depositedAmount += restakerDepositedAmount;
            mintedShares += restakerMintedShares;
        }
    }

    function _symbioticMintAndStakeInVault(address vault, address restaker, uint256 amount)
        internal
        returns (uint256 depositedAmount, uint256 mintedShares)
    {
        vm.startPrank(restaker);
        address collateral = IVault(vault).collateral();
        MockERC20(collateral).mint(restaker, amount);
        MockERC20(collateral).approve(address(vault), amount);
        (depositedAmount, mintedShares) = IVault(vault).deposit(restaker, amount);
        vm.stopPrank();
    }

    function _proportionallyWithdrawFromVault(TestEnvConfig memory env, address vault, uint256 amount, bool all)
        internal
    {
        for (uint256 i = 0; i < env.testUsers.restakers.length; i++) {
            if (all) {
                amount = IVault(vault).activeSharesOf(env.testUsers.restakers[i]);
                vm.startPrank(env.testUsers.restakers[i]);
                IVault(vault).redeem(env.testUsers.restakers[i], amount);
                vm.stopPrank();
            } else {
                vm.startPrank(env.testUsers.restakers[i]);
                IVault(vault).withdraw(env.testUsers.restakers[i], amount);
                vm.stopPrank();
            }
        }
    }

    function _withdrawFromVault(address vault, address restaker, uint256 amount) internal {
        vm.startPrank(restaker);
        IVault(vault).withdraw(restaker, amount);
        vm.stopPrank();
    }
}
