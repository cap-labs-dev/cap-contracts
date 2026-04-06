// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MockERC20 } from "../../../../mocks/MockERC20.sol";
import { TestEnvConfig, TestUsersConfig } from "../../../interfaces/TestDeployConfig.sol";

import { TimeUtils } from "../../../utils/TimeUtils.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Vm } from "forge-std/Vm.sol";

contract InitSymbioticVaultLiquidity is TimeUtils {
    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Seeds each Symbiotic vault in the `env` with deposits from all `testUsers.restakers`.
    /// Assumes vault collateral is a `MockERC20` (we mint directly).
    function _initSymbioticVaultsLiquidity(TestEnvConfig memory env, uint256 amountNoDecimals) internal {
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            address vault = env.symbiotic.vaults[i];
            _initSymbioticVaultLiquidityForAgent(env.testUsers, vault, amountNoDecimals);
        }

        _timeTravel(28 days);
    }

    /// @dev Deposits into a single Symbiotic vault for every restaker in `testUsers`.
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

    /// @dev Mints vault collateral to `restaker` (mock-only) then deposits into the Symbiotic vault.
    function _symbioticMintAndStakeInVault(address vault, address restaker, uint256 amount)
        internal
        returns (uint256 depositedAmount, uint256 mintedShares)
    {
        _vm.startPrank(restaker);
        address collateral = IVault(vault).collateral();
        MockERC20(collateral).mint(restaker, amount);
        MockERC20(collateral).approve(address(vault), amount);
        (depositedAmount, mintedShares) = IVault(vault).deposit(restaker, amount);
        _vm.stopPrank();
    }

    /// @dev Withdraws proportionally from a vault for every restaker.
    function _proportionallyWithdrawFromVault(TestEnvConfig memory env, address vault, uint256 amount, bool all)
        internal
    {
        for (uint256 i = 0; i < env.testUsers.restakers.length; i++) {
            if (all) {
                amount = IVault(vault).activeSharesOf(env.testUsers.restakers[i]);
                _vm.startPrank(env.testUsers.restakers[i]);
                IVault(vault).redeem(env.testUsers.restakers[i], amount);
                _vm.stopPrank();
            } else {
                _vm.startPrank(env.testUsers.restakers[i]);
                IVault(vault).withdraw(env.testUsers.restakers[i], amount);
                _vm.stopPrank();
            }
        }
    }

    /// @dev Withdraw a single restaker from a vault.
    function _withdrawFromVault(address vault, address restaker, uint256 amount) internal {
        _vm.startPrank(restaker);
        IVault(vault).withdraw(restaker, amount);
        _vm.stopPrank();
    }
}
