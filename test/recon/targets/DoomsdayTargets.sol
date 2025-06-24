// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { MockERC20 } from "@recon/MockERC20.sol";

// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";
import { console2 } from "forge-std/console2.sol";

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// Makes a handler have no side effects
    /// The fuzzer will call this anyway, and because it reverts it will be removed from shrinking
    /// Replace the "withGhosts" with "stateless" to make the code clean
    modifier stateless() {
        _;
        revert("stateless");
    }

    /// @dev Property: liquidate should always succeed for liquidatable agent
    /// @dev Property: Emergency liquidations should always be available when emergency health is below 1e27
    /// @dev Property: liquidating a healthy agent should not generate bad debt
    function doomsday_liquidate(uint256 _amount) public stateless {
        if (_amount == 0) {
            return;
        }

        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 healthBefore) = _getAgentParams(_getActor());
        uint256 emergencyLiquidationHealth = totalDelegation * lender.emergencyLiquidationThreshold() / totalDebt;

        // Note: this function will always be called by address(this) (Liquidator will be address(this))
        try lender.liquidate(_getActor(), _getAsset(), _amount) {
            (,,,,, uint256 healthAfter) = _getAgentParams(_getActor());

            if (healthBefore > RAY) {
                gt(healthAfter, RAY, "liquidating a healthy agent should not generate bad debt");
            }
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "HealthFactorNotBelowThreshold()")
                || checkError(reason, "GracePeriodNotOver()") || checkError(reason, "LiquidationExpired()")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)")
                || checkError(reason, "InvalidBurnAmount()") || checkError(reason, "PriceError(address)");
            bool protocolPaused = capToken.paused();
            bool assetPaused = capToken.paused(_getAsset());
            (, address vault,,,,,) = lender.reservesData(_getAsset());
            bool isReserve = vault != address(0); // token must be a reserve in the lending vault

            // precondition: must not error for one of the expected reasons
            if (!expectedError && !protocolPaused && !assetPaused && totalDebt > 0 && isReserve) {
                gt(
                    emergencyLiquidationHealth,
                    RAY,
                    "Emergency liquidation is not available when emergency health is below 1e27"
                );
                gt(healthBefore, RAY, "liquidate should always succeed for liquidatable agent");
            }
        }
    }

    /// @dev Property: repay should always succeed for agent that has debt
    function doomsday_repay(uint256 _amount) public stateless {
        (,, uint256 totalDebt,,,) = lender.agent(_getActor());

        // Preconditions: should have debt, enough allowance and balance to repay
        if (
            totalDebt == 0 || MockERC20(_getAsset()).allowance(_getActor(), address(lender)) < _amount
                || MockERC20(_getAsset()).balanceOf(_getActor()) < _amount
        ) {
            return;
        }

        vm.prank(_getActor());
        try lender.repay(_getAsset(), _amount, _getActor()) {
            // success
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "InvalidBurnAmount()")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)"); // fractional reserve loss
            bool enoughAllowance = MockERC20(_getAsset()).allowance(_getActor(), address(lender)) >= _amount;
            bool enoughBalance = MockERC20(_getAsset()).balanceOf(_getActor()) >= _amount;
            bool protocolPaused = capToken.paused();
            bool assetPaused = capToken.paused(_getAsset());
            (, address vault,,,,,) = lender.reservesData(_getAsset());
            bool isReserve = vault != address(0); // token must be a reserve in the lender

            if (
                !expectedError && !protocolPaused && !assetPaused && enoughAllowance && enoughBalance && _amount > 0
                    && isReserve
            ) {
                t(false, "repay should always succeed for agent that has debt");
            }
        }
    }

    /// @dev Property: DebtToken total supply ≥ total vault debt at all times
    // NOTE: stateless because we're realizing restaker interest since this contributes to the total vault debt
    function doomsday_debt_token_solvency() public stateless {
        address[] memory assets = capToken.assets();
        address[] memory agents = delegation.agents();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            (,, address _debtToken,,,,) = lender.reservesData(asset);

            if (_debtToken == address(0)) {
                continue;
            }

            // realize restaker interest for all agents so that we have the correct amount of debtToken minted to each agent
            for (uint256 j = 0; j < agents.length; j++) {
                lender.realizeRestakerInterest(agents[j], asset);
            }

            uint256 totalDebtTokenSupply = MockERC20(_debtToken).totalSupply();

            uint256 totalVaultDebt = 0;
            uint256 totalDebtTokenBalance = 0;
            for (uint256 j = 0; j < agents.length; j++) {
                totalDebtTokenBalance += MockERC20(_debtToken).balanceOf(agents[j]);
                totalVaultDebt += lender.debt(agents[j], asset);
            }
            console2.log("totalDebtTokenBalance %e", totalDebtTokenBalance);
            console2.log("totalVaultDebt %e", totalVaultDebt);
            console2.log("totalDebtTokenSupply %e", totalDebtTokenSupply);

            eq(totalDebtTokenSupply, totalVaultDebt, "DebtToken totalSupply < total vault debt");
        }
    }
}
